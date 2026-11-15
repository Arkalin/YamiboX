import Observation
import SwiftUI
import UIKit
import YamiboXCore

@MainActor
@Observable
final class ReaderExternalDisplayCoordinator {
    enum Phase { case local, preparing, external, deviceInteraction, suspended }

    @MainActor
    private final class Candidate {
        let session: ReaderSession
        weak var model: YamiboAppModel?
        weak var host: ReaderExternalDisplayRegistrationHost.Host?
        var navigator: ForumDestinationNavigator
        let contentID: UUID
        var lastUse: UInt64

        init(session: ReaderSession, model: YamiboAppModel, host: ReaderExternalDisplayRegistrationHost.Host?,
             navigator: ForumDestinationNavigator, lastUse: UInt64) {
            self.session = session
            self.model = model
            self.host = host
            self.navigator = navigator
            self.contentID = session.contentID
            self.lastUse = lastUse
        }
    }

    private struct Lease {
        let owner: Candidate
        let connection: ReaderExternalDisplaySceneDelegate
        let viewport: ReaderViewportLifetime
        let generation = UUID()
    }

    private struct FailedPresentation {
        let sceneID: String
        let contentID: UUID
    }

    private(set) var phase = Phase.local
    private(set) var sessionID: UUID?
    private var suspendedFrom = Phase.local
    @ObservationIgnored private(set) var deviceFrameDuringPreparation: UIView?
    let pointer = ReaderExternalInput()
    @ObservationIgnored private var candidates: [String: Candidate] = [:]
    @ObservationIgnored private var scenePhases: [String: ScenePhase] = [:]
    private var focusedWindowID: String?
    @ObservationIgnored private var usage: UInt64 = 0
    @ObservationIgnored private var needsExplicitActivation = false
    @ObservationIgnored private var elected: Candidate?
    @ObservationIgnored private var reservedOwner: Candidate?
    @ObservationIgnored private weak var registrationHost: ReaderExternalDisplayRegistrationHost.Host?
    @ObservationIgnored private var registrationID: UUID?
    @ObservationIgnored private var lease: Lease?
    @ObservationIgnored private var failedPresentation: FailedPresentation?
    @ObservationIgnored private var disconnectedPreparation: Task<Void, Never>?
    @ObservationIgnored private var closingSessionID: UUID?
    @ObservationIgnored private var scheduledEvaluation = false
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private let wakefulness = ReaderTrackpadWakefulness()
    @ObservationIgnored private var settingsObservation: Task<Void, Never>?
    @ObservationIgnored private var isTakeoverEnabled = false

    init(settingsStore: SettingsStore) {
        ReaderExternalDisplayScenes.shared.coordinator = self
        // Subscribe before loading so writes during startup are not missed.
        let changes = settingsStore.changes()
        settingsObservation = Task { [weak self] in
            let initial = await settingsStore.load()
            guard !Task.isCancelled else { return }
            self?.setTakeoverEnabled(initial.system.externalDisplay.isEnabled)
            for await _ in changes {
                let settings = await settingsStore.load()
                guard !Task.isCancelled, let self else { return }
                setTakeoverEnabled(settings.system.externalDisplay.isEnabled)
            }
        }
    }

    deinit { settingsObservation?.cancel() }

    private func setTakeoverEnabled(_ enabled: Bool) {
        guard isTakeoverEnabled != enabled else { return }
        isTakeoverEnabled = enabled
        if enabled {
            evaluate()
        } else {
            disconnectedPreparation?.cancel()
            disconnectedPreparation = nil
            failedPresentation = nil
            reservedOwner = nil
            // Keep the candidates and any device panel so they can finish
            // locally, and so opting in again does not require a reconnect.
            release(requireActivation: false)
            elect(nil)
        }
    }

    func offer(session: ReaderSession, model: YamiboAppModel, host: ReaderExternalDisplayRegistrationHost.Host?,
               navigator: ForumDestinationNavigator, eligible: Bool) {
        guard let id = model.windowID else { return }
        guard eligible, !session.isClosed, session.content.resumeRoute != nil else {
            withdraw(session: session, windowID: id, requireActivation: session.isClosed)
            return
        }
        if let existing = candidates[id], existing.session === session, existing.contentID == session.contentID {
            if let host { existing.host = host }
        } else {
            let previous = candidates[id]
            let shouldKeepOwner = previous?.session === session && previous === reservedOwner
            if let previous, previous === reservedOwner || previous === lease?.owner {
                release(requireActivation: false)
                reservedOwner = nil
            }
            let candidate = Candidate(session: session, model: model, host: host, navigator: navigator,
                lastUse: previous?.session === session ? previous?.lastUse ?? 0 : 0)
            candidates[id] = candidate
            if shouldKeepOwner { reservedOwner = candidate }
            needsExplicitActivation = false
        }
        evaluate()
    }

    func withdraw(session: ReaderSession, windowID: String, requireActivation: Bool) {
        guard let candidate = candidates[windowID], candidate.session === session else { return }
        candidates[windowID] = nil
        let previouslyOwned = lease?.owner === candidate
        if reservedOwner === candidate {
            reservedOwner = nil
            if requireActivation { needsExplicitActivation = true }
        }
        if previouslyOwned { release(requireActivation: requireActivation) }
        if elected === candidate { elect(nil) }
        evaluate()
    }

    func pauseForReaderNavigation(_ session: ReaderSession) {
        guard let lease, lease.owner.session === session else { return }
        // This same cover also hosts the native post. Keep the system's
        // connection, but remove the reader and all its input; UIKit need not
        // connect a second accessory when the user reenters reading.
        release(requireActivation: false)
    }

    func windowDisconnected(_ id: String, discarded: Bool = false) {
        if !discarded { scenePhaseChanged(.background, windowID: id); return }
        if let candidate = candidates[id] {
            withdraw(session: candidate.session, windowID: id, requireActivation: reservedOwner === candidate || lease?.owner === candidate)
            candidate.session.close()
        }
        scenePhases[id] = nil
        if focusedWindowID == id { focusedWindowID = nil }
    }

    func focusChanged(_ id: String) {
        focusedWindowID = id
        if let lease {
            if phase == .external || phase == .deviceInteraction {
                lease.connection.conceal(!showsReaderOnExternalDisplay)
            }
            pointer.setEnabled(showsReaderOnExternalDisplay && phase == .external)
            wakefulness.setNeeded(showsReaderOnExternalDisplay && phase == .external)
        }
        if lease == nil { evaluate() }
    }

    func acceptsPeripheralInput(windowID: String) -> Bool {
        guard let lease, lease.owner.model?.windowID == windowID else {
            // A detached editor must not let this window's old reader or any
            // capture callback consume keystrokes from its sheet.
            return candidates[windowID]?.session.deviceInteraction == nil
        }
        return phase == .external && showsReaderOnExternalDisplay && scenePhases[windowID] == .active
    }

    func userOperated(_ id: String) {
        guard let candidate = candidates[id] else { return }
        usage &+= 1
        candidate.lastUse = usage
        needsExplicitActivation = false
        if lease == nil { evaluate() }
    }

    func isKeepingOwner(_ session: ReaderSession) -> Bool {
        reservedOwner?.session === session
    }

    var isWaitingForExternalFrame: Bool {
        phase == .preparing || (phase == .suspended && suspendedFrom == .preparing)
    }

    var showsReaderOnExternalDisplay: Bool {
        (phase == .external || phase == .deviceInteraction) &&
            (focusedWindowID == nil || focusedWindowID == lease?.owner.model?.windowID)
    }

    func scenePhaseChanged(_ value: ScenePhase, windowID: String) {
        scenePhases[windowID] = value
        if let lease, lease.owner.model?.windowID == windowID, closingSessionID != lease.owner.session.id {
            if value != .active {
                if phase != .suspended {
                    lease.connection.conceal(true)
                    lease.owner.session.saveReadingPosition()
                    lease.viewport.setSuspended(true, capturingPosition: false)
                    suspendedFrom = phase
                    setPhase(.suspended)
                    timeout?.cancel()
                }
            } else if phase == .suspended {
                if focusedWindowID == nil || scenePhases[focusedWindowID ?? ""] != .active {
                    focusedWindowID = windowID
                }
                lease.viewport.setSuspended(false)
                if suspendedFrom == .external || suspendedFrom == .deviceInteraction || lease.viewport.hasRendered {
                    setPhase(lease.owner.session.deviceInteraction == nil ? .external : .deviceInteraction)
                    lease.connection.conceal(!showsReaderOnExternalDisplay)
                } else {
                    beginPreparing(lease)
                }
            }
        }
        if lease == nil { evaluate() }
    }

    func closeReader(_ session: ReaderSession, contentID: UUID) {
        guard !session.isClosed, session.contentID == contentID, closingSessionID != session.id else { return }
        guard let lease, lease.owner.session === session else { session.close(); return }
        let sessionID = session.id
        closingSessionID = sessionID
        timeout?.cancel()
        lease.connection.conceal(true)
        lease.viewport.setSuspended(true)
        setPhase(.suspended)
        // Keep the owner controller in the hierarchy long enough to publish
        // black. Removing its cover first disconnects the accessory immediately.
        Task { [weak self, weak session] in
            try? await Task.sleep(for: .milliseconds(150))
            if let session, session.contentID == contentID { session.close() }
            guard let self, closingSessionID == sessionID else { return }
            closingSessionID = nil
            evaluate()
        }
    }

    func beginDeviceInteraction(_ interaction: ReaderDeviceInteraction, session: ReaderSession) {
        guard let lease, phase == .external, lease.owner.session === session,
              let model = lease.owner.model, interaction.validate(session: session, appModel: model), !session.isClosed,
              session.deviceInteraction == nil else { return }
        setPhase(.deviceInteraction)
        lease.viewport.setInputPaused(true)
        lease.owner.model?.peripheralInput.resetPressState()
        session.deviceInteraction = interaction
    }

    func finishDeviceInteraction(id: UUID, session: ReaderSession) {
        guard let interaction = session.deviceInteraction, interaction.id == id,
              let model = candidates.values.first(where: { $0.session === session })?.model,
              interaction.validate(session: session, appModel: model), !session.isClosed else { return }
        session.deviceInteraction = nil
        guard let lease, lease.owner.session === session else {
            evaluate()
            return
        }
        lease.viewport.setInputPaused(false)
        guard phase == .deviceInteraction else { return }
        if let windowID = lease.owner.model?.windowID, scenePhases[windowID] == .active {
            setPhase(.external)
            lease.connection.conceal(!showsReaderOnExternalDisplay)
        } else {
            lease.connection.conceal(true)
            lease.viewport.setSuspended(true)
            suspendedFrom = .external
            setPhase(.suspended)
        }
    }

    func displayConnected() { evaluate() }

    func displayDisconnected(_ connection: ReaderExternalDisplaySceneDelegate) {
        if failedPresentation?.sceneID == connection.sceneIdentifier { failedPresentation = nil }
        guard lease?.connection === connection else {
            if lease == nil { scheduleEvaluation() }
            return
        }
        let wasPreparing = phase == .preparing
        let owner = lease?.owner
        let generation = registrationID
        let ownerWindowID = owner?.model?.windowID
        let ownerPhase = ownerWindowID.flatMap { scenePhases[$0] }
        // An accessory can disconnect when UIKit changes the focused device
        // scene (including app-switcher transitions). Keep its owner reserved
        // while inactive so another open book isn't shown on the external display.
        reservedOwner = owner
        release(requireActivation: false)
        disconnectedPreparation?.cancel()
        if wasPreparing && ownerPhase == .active {
            disconnectedPreparation = Task { [weak self, weak owner] in
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                guard let self, lease == nil, registrationID == generation else { return }
                if #available(iOS 27, *), owner?.host?.isAccessoryAvailable == true { return }
                owner?.model?.externalDisplayFailure = true
            }
        }
        scheduleEvaluation()
    }

    private func scheduleEvaluation() {
        guard !scheduledEvaluation else { return }
        scheduledEvaluation = true
        Task { [weak self] in
            guard let self else { return }
            scheduledEvaluation = false
            evaluate()
        }
    }

    private func evaluate() {
        guard isTakeoverEnabled, lease == nil, closingSessionID == nil else { return }
        guard !needsExplicitActivation else { elect(nil); return }
        if let reservedOwner, !canTakeOver(reservedOwner) { return }
        let candidate = reservedOwner ?? candidates.values.filter {
            canTakeOver($0)
        }.max { lhs, rhs in
            if lhs.lastUse != rhs.lastUse { return lhs.lastUse < rhs.lastUse }
            if lhs.model?.windowID == focusedWindowID { return false }
            if rhs.model?.windowID == focusedWindowID { return true }
            return (lhs.model?.windowID ?? "") < (rhs.model?.windowID ?? "")
        }
        elect(candidate)
        guard lease == nil, let candidate, let model = candidate.model else { return }
        let isRestoringDeviceInteraction = candidate === reservedOwner && candidate.session.deviceInteraction != nil
        guard isRestoringDeviceInteraction || candidate.session.viewport.hasRendered else {
            // Let the device finish its first layout before passing position
            // to a viewport on an already-connected display.
            candidate.session.viewport.didRender = { [weak self] in self?.evaluate() }
            return
        }
        guard let connection = ReaderExternalDisplayScenes.shared.available.first(where: {
                  $0.scene != nil && $0.registrationID == registrationID &&
                  ($0.sceneIdentifier != failedPresentation?.sceneID || candidate.contentID != failedPresentation?.contentID)
              }) else { return }
        deviceFrameDuringPreparation = isRestoringDeviceInteraction
            ? nil : candidate.host?.viewIfLoaded?.window?.snapshotView(afterScreenUpdates: false)
        let viewport = candidate.session.beginExternalViewport()
        reservedOwner = candidate
        disconnectedPreparation?.cancel()
        model.externalDisplayFailure = false
        pointer.reset()
        if !isRestoringDeviceInteraction { candidate.session.hideReaderChrome() }
        let lease = Lease(owner: candidate, connection: connection, viewport: viewport)
        self.lease = lease
        connection.displayCoordinator = self
        sessionID = candidate.session.id
        beginPreparing(lease)
        guard connection.show(ReaderExternalSurface(
            display: self, session: candidate.session, navigator: candidate.navigator, appModel: model, viewport: viewport
        )) else {
            fail(lease.generation)
            return
        }
        pointer.targets.window = connection.window
    }

    private func canTakeOver(_ owner: Candidate) -> Bool {
        guard let id = owner.model?.windowID, scenePhases[id] == .active,
              !owner.session.isClosed, owner.session.contentID == owner.contentID else { return false }
        if owner.session.deviceInteraction != nil {
            // A foreground transition can reconnect an accessory while its
            // owner still has a device sheet. Keep that sheet and restore only
            // the external reader, without re-enabling remote input.
            guard owner === reservedOwner else { return false }
        } else {
            guard !owner.session.isShowingDevicePanel else { return false }
        }
        if #available(iOS 27, *) { return owner.host != nil }
        return true
    }

    private func elect(_ candidate: Candidate?) {
        let host = candidate?.host
        guard elected !== candidate || registrationHost !== host else { return }
        let previousHost = registrationHost
        elected = candidate
        registrationHost = host
        registrationID = nil
        if previousHost !== host { previousHost?.disableAfterPrivacyFrame() }
        if #available(iOS 27, *), let host {
            let id = host.registrationID ?? UUID()
            registrationID = id
            host.start(id: id)
        }
    }

    private func beginPreparing(_ lease: Lease) {
        setPhase(.preparing)
        let generation = lease.generation
        lease.viewport.didRender = { [weak self] in self?.displayReady(generation) }
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.fail(generation)
        }
    }

    private func displayReady(_ generation: UUID) {
        guard let lease, lease.generation == generation, phase == .preparing,
              let id = lease.owner.model?.windowID, scenePhases[id] == .active,
              !lease.owner.session.isClosed, lease.owner.session.contentID == lease.owner.contentID else { return }
        timeout?.cancel()
        timeout = nil
        lease.viewport.didRender = nil
        let hasDeviceInteraction = lease.owner.session.deviceInteraction != nil
        lease.viewport.setInputPaused(hasDeviceInteraction)
        setPhase(hasDeviceInteraction ? .deviceInteraction : .external)
        lease.connection.conceal(!showsReaderOnExternalDisplay)
    }

    private func fail(_ generation: UUID) {
        guard let lease, lease.generation == generation else { return }
        YamiboLog.reader.info("External reader preparation did not complete; restoring the device viewport")
        lease.owner.model?.externalDisplayFailure = true
        failedPresentation = lease.connection.sceneIdentifier.map {
            FailedPresentation(sceneID: $0, contentID: lease.owner.contentID)
        }
        reservedOwner = nil
        release(requireActivation: false)
    }

    private func release(requireActivation: Bool) {
        needsExplicitActivation = requireActivation
        guard let lease else { return }
        self.lease = nil
        sessionID = nil
        timeout?.cancel()
        timeout = nil
        setPhase(.local)
        lease.connection.conceal(true)
        if !lease.owner.session.isClosed { lease.owner.session.returnToDeviceViewport() }
        lease.connection.retireWindow()
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        if !isWaitingForExternalFrame { deviceFrameDuringPreparation = nil }
        let canUseTrackpad = phase == .external && showsReaderOnExternalDisplay
        pointer.setEnabled(canUseTrackpad)
        wakefulness.setNeeded(canUseTrackpad)
        if phase == .local { pointer.reset() }
    }
}

@MainActor
private final class ReaderTrackpadWakefulness {
    private var previous: Bool?

    func setNeeded(_ needed: Bool) {
        if needed, previous == nil {
            previous = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !needed, let previous {
            UIApplication.shared.isIdleTimerDisabled = previous
            self.previous = nil
        }
    }
}

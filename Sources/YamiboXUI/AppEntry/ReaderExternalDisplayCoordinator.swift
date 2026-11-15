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
    @ObservationIgnored private var focusedWindowID: String?
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

    init() { ReaderExternalDisplayScenes.shared.coordinator = self }

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
            let focused = lease.owner.model?.windowID == id
            pointer.setEnabled(focused && phase == .external)
            wakefulness.setNeeded(focused && phase == .external)
        }
        if lease == nil { evaluate() }
    }

    func acceptsPeripheralInput(windowID: String) -> Bool {
        guard let lease, lease.owner.model?.windowID == windowID else {
            // A detached editor must not let this window's old reader or any
            // capture callback consume keystrokes from its sheet.
            return candidates[windowID]?.session.deviceInteraction == nil
        }
        return phase == .external && scenePhases[windowID] == .active && pointer.menu == nil
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

    func scenePhaseChanged(_ value: ScenePhase, windowID: String) {
        scenePhases[windowID] = value
        if let lease, lease.owner.model?.windowID == windowID, closingSessionID != lease.owner.session.id {
            if value != .active {
                if phase != .deviceInteraction && phase != .suspended {
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
                if suspendedFrom == .external || lease.viewport.hasRendered {
                    setPhase(.external)
                    lease.connection.conceal(false)
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
        lease.connection.conceal(true)
        setPhase(.deviceInteraction)
        lease.viewport.setSuspended(true)
        lease.owner.model?.peripheralInput.resetPressState()
        session.deviceInteraction = interaction
    }

    func finishDeviceInteraction(id: UUID, session: ReaderSession) {
        guard let interaction = session.deviceInteraction, interaction.id == id,
              let model = candidates.values.first(where: { $0.session === session })?.model,
              interaction.validate(session: session, appModel: model), !session.isClosed else { return }
        session.deviceInteraction = nil
        interaction.onReturn()
        guard let lease, lease.owner.session === session, phase == .deviceInteraction else {
            evaluate()
            return
        }
        if let windowID = lease.owner.model?.windowID, scenePhases[windowID] == .active {
            lease.viewport.setSuspended(false)
            setPhase(.external)
            lease.connection.conceal(false)
        } else {
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
        guard lease == nil, closingSessionID == nil else { return }
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
        guard candidate.session.viewport.hasRendered else {
            // Let the device finish its first layout before passing position
            // to a viewport on an already-connected display.
            candidate.session.viewport.didRender = { [weak self] in self?.evaluate() }
            return
        }
        guard let connection = ReaderExternalDisplayScenes.shared.available.first(where: {
                  $0.scene != nil && $0.registrationID == registrationID &&
                  ($0.sceneIdentifier != failedPresentation?.sceneID || candidate.contentID != failedPresentation?.contentID)
              }) else { return }
        deviceFrameDuringPreparation = candidate.host?.viewIfLoaded?.window?.snapshotView(afterScreenUpdates: false)
        let viewport = candidate.session.beginExternalViewport()
        reservedOwner = candidate
        disconnectedPreparation?.cancel()
        model.externalDisplayFailure = false
        pointer.reset()
        candidate.session.hideReaderChrome()
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
              !owner.session.isClosed, !owner.session.isShowingDevicePanel,
              owner.session.deviceInteraction == nil, owner.session.contentID == owner.contentID else { return false }
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
        setPhase(.external)
        lease.connection.conceal(false)
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
        let canUseTrackpad = phase == .external &&
            (focusedWindowID == nil || focusedWindowID == lease?.owner.model?.windowID)
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

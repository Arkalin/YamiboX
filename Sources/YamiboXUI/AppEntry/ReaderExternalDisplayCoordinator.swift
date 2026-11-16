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
        var interfaceStyle: UIUserInterfaceStyle
        let contentID: UUID
        var lastUse: UInt64
        var deviceAdmissionWait: Task<Void, Never>?

        init(session: ReaderSession, model: YamiboAppModel, host: ReaderExternalDisplayRegistrationHost.Host?,
             navigator: ForumDestinationNavigator, interfaceStyle: UIUserInterfaceStyle, lastUse: UInt64) {
            self.session = session
            self.model = model
            self.host = host
            self.navigator = navigator
            self.interfaceStyle = interfaceStyle
            self.contentID = session.contentID
            self.lastUse = lastUse
        }

        deinit { deviceAdmissionWait?.cancel() }

        func cancelDeviceAdmissionWait() {
            deviceAdmissionWait?.cancel()
            deviceAdmissionWait = nil
        }
    }

    private struct Lease {
        let owner: Candidate
        let connection: ReaderExternalDisplaySceneDelegate
        let viewport: ReaderViewportLifetime
        let generation: UUID
    }

    private struct FailedPresentation {
        let sceneID: String
        let contentID: UUID
    }

    private(set) var phase = Phase.local
    private(set) var sessionID: UUID?
    private var isDeviceMenuPresented = false
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
    @ObservationIgnored private var hasLoadedTakeoverSettings = false

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
        guard !hasLoadedTakeoverSettings || isTakeoverEnabled != enabled else { return }
        hasLoadedTakeoverSettings = true
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
            evaluate()
        }
    }

    func offer(session: ReaderSession, model: YamiboAppModel, host: ReaderExternalDisplayRegistrationHost.Host?,
               navigator: ForumDestinationNavigator, interfaceStyle: UIUserInterfaceStyle, eligible: Bool) {
        guard let id = model.windowID else { return }
        guard eligible, !session.isClosed, session.content.resumeRoute != nil else {
            withdraw(session: session, windowID: id, requireActivation: session.isClosed)
            return
        }
        if let existing = candidates[id], existing.session === session, existing.contentID == session.contentID {
            if let host { existing.host = host }
            if existing.interfaceStyle != interfaceStyle {
                existing.interfaceStyle = interfaceStyle
                if let lease, lease.owner === existing {
                    lease.connection.window?.overrideUserInterfaceStyle = interfaceStyle
                }
            }
        } else {
            let previous = candidates[id]
            previous?.cancelDeviceAdmissionWait()
            let shouldKeepOwner = previous?.session === session && previous === reservedOwner
            if let previous, previous === reservedOwner || previous === lease?.owner {
                release(requireActivation: false)
                reservedOwner = nil
            }
            let candidate = Candidate(session: session, model: model, host: host, navigator: navigator, interfaceStyle: interfaceStyle,
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
        candidate.cancelDeviceAdmissionWait()
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
            if !showsReaderOnExternalDisplay { isDeviceMenuPresented = false }
            synchronizeInput()
        }
        if lease == nil { evaluate() }
    }

    func acceptsPeripheralInput(windowID: String) -> Bool {
        guard let lease, lease.owner.model?.windowID == windowID else {
            // A detached editor must not let this window's old reader or any
            // capture callback consume keystrokes from its sheet.
            return candidates[windowID]?.session.deviceInteraction == nil
        }
        return canUseTrackpad && scenePhases[windowID] == .active
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
        phase == .preparing
    }

    var showsReaderOnExternalDisplay: Bool {
        (phase == .external || phase == .deviceInteraction) &&
            (focusedWindowID == nil || focusedWindowID == lease?.owner.model?.windowID)
    }

    private var canUseTrackpad: Bool {
        phase == .external && showsReaderOnExternalDisplay && !isDeviceMenuPresented
    }

    func deviceMenu(for session: ReaderSession) -> ReaderViewportLifetime.DeviceMenu? {
        guard let lease, lease.owner.session === session,
              lease.owner.contentID == session.contentID, !session.isClosed else { return nil }
        return lease.viewport.deviceMenu
    }

    func isShowingDeviceMenu(for session: ReaderSession) -> Bool {
        isDeviceMenuPresented && deviceMenu(for: session) != nil
    }

    func showDeviceMenu(for session: ReaderSession, from viewport: ReaderViewportLifetime? = nil) {
        guard canUseTrackpad, let lease, lease.owner.session === session,
              viewport == nil || lease.viewport === viewport,
              lease.owner.contentID == session.contentID, !session.isClosed,
              !session.isShowingDevicePanel, lease.viewport.deviceMenu != nil else { return }
        isDeviceMenuPresented = true
        synchronizeInput()
        lease.owner.model?.peripheralInput.resetPressState()
    }

    func dismissDeviceMenu(for session: ReaderSession) {
        guard isDeviceMenuPresented, lease?.owner.session === session else { return }
        isDeviceMenuPresented = false
        synchronizeInput(revealCursor: false)
    }

    func scenePhaseChanged(_ value: ScenePhase, windowID: String) {
        scenePhases[windowID] = value
        if let lease, lease.owner.model?.windowID == windowID, closingSessionID != lease.owner.session.id {
            if value != .active {
                if phase == .preparing {
                    // A not-yet-visible viewport may still await a one-shot
                    // layout or restoration callback. Restart its attachment
                    // on foreground instead of suspending it mid-admission.
                    release(requireActivation: false, permitsDeviceReader: false)
                    evaluate()
                    return
                }
                if phase != .suspended {
                    lease.connection.conceal(true)
                    lease.owner.session.saveReadingPosition()
                    lease.viewport.setSuspended(true, capturingPosition: false)
                    setPhase(.suspended)
                    timeout?.cancel()
                }
            } else if phase == .suspended {
                if focusedWindowID == nil || scenePhases[focusedWindowID ?? ""] != .active {
                    focusedWindowID = windowID
                }
                lease.viewport.setSuspended(false)
                setPhase(lease.owner.session.deviceInteraction == nil ? .external : .deviceInteraction)
                lease.connection.conceal(!showsReaderOnExternalDisplay)
            }
        }
        if lease == nil { evaluate() }
    }

    func closeReader(_ session: ReaderSession, contentID: UUID) {
        guard !session.isClosed, session.contentID == contentID, closingSessionID != session.id else { return }
        guard let lease, lease.owner.session === session else { session.close(); return }
        if phase == .preparing {
            // The external window is already black; no privacy frame to wait for.
            session.close()
            return
        }
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
        guard phase == .deviceInteraction else { return }
        if let windowID = lease.owner.model?.windowID, scenePhases[windowID] == .active {
            setPhase(.external)
            lease.connection.conceal(!showsReaderOnExternalDisplay)
        } else {
            lease.connection.conceal(true)
            lease.viewport.setSuspended(true)
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
        release(requireActivation: false, permitsDeviceReader: false)
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
        let awaitingAccessory = evaluateExternalPresentation()
        updateDeviceAdmission(awaitingAccessory: awaitingAccessory)
    }

    /// Returns the elected owner whose registration may still yield a scene.
    private func evaluateExternalPresentation() -> Candidate? {
        guard hasLoadedTakeoverSettings, isTakeoverEnabled, lease == nil, closingSessionID == nil else { return nil }
        guard !needsExplicitActivation else { elect(nil); return nil }
        if let reservedOwner, !canTakeOver(reservedOwner) { return nil }
        let candidate = reservedOwner ?? candidates.values.filter {
            canTakeOver($0)
        }.max { lhs, rhs in
            if lhs.lastUse != rhs.lastUse { return lhs.lastUse < rhs.lastUse }
            if lhs.model?.windowID == focusedWindowID { return false }
            if rhs.model?.windowID == focusedWindowID { return true }
            return (lhs.model?.windowID ?? "") < (rhs.model?.windowID ?? "")
        }
        elect(candidate)
        guard lease == nil, let candidate, let model = candidate.model else { return nil }
        let isRestoringDeviceInteraction = candidate === reservedOwner && candidate.session.deviceInteraction != nil
        guard let connection = ReaderExternalDisplayScenes.shared.available.first(where: {
                  $0.scene != nil && $0.registrationID == registrationID &&
                  ($0.sceneIdentifier != failedPresentation?.sceneID || candidate.contentID != failedPresentation?.contentID)
              }) else {
            if #available(iOS 27, *), !candidate.session.permitsDeviceReader,
               candidate.host?.sampledAvailability != false,
               failedPresentation?.contentID != candidate.contentID {
                return candidate
            }
            return nil
        }
        guard isRestoringDeviceInteraction || !candidate.session.permitsDeviceReader ||
              candidate.session.viewport.hasRendered else {
            // A device viewport already admitted to read locally can finish
            // restoring its position before a hot-plug handoff.
            candidate.session.viewport.didRender = { [weak self] in self?.evaluate() }
            return nil
        }
        guard let bounds = connection.scene?.screen.nativeBounds,
              let width = Int(exactly: bounds.width), let height = Int(exactly: bounds.height),
              let resolution = ReaderSettingsTarget.Resolution(width: width, height: height) else {
            failedPresentation = connection.sceneIdentifier.map {
                FailedPresentation(sceneID: $0, contentID: candidate.contentID)
            }
            reservedOwner = nil
            model.externalDisplayFailure = true
            return nil
        }
        deviceFrameDuringPreparation = isRestoringDeviceInteraction || !candidate.session.viewport.hasRendered
            ? nil : candidate.host?.viewIfLoaded?.window?.snapshotView(afterScreenUpdates: false)
        let generation = UUID()
        let viewport = candidate.session.beginExternalViewport(
            resolution: resolution,
            onTrackpadSensitivityChange: { [weak self] sensitivity in
                guard let self, lease?.generation == generation else { return }
                pointer.sensitivity = CGFloat(sensitivity)
            },
            onFailure: { [weak self] in self?.fail(generation) }
        )
        reservedOwner = candidate
        disconnectedPreparation?.cancel()
        model.externalDisplayFailure = false
        pointer.reset()
        if !isRestoringDeviceInteraction { candidate.session.hideReaderChrome() }
        let lease = Lease(owner: candidate, connection: connection, viewport: viewport, generation: generation)
        if case .novel = candidate.session.content { viewport.traceExternalNovelPreparation(id: generation) }
        self.lease = lease
        connection.displayCoordinator = self
        sessionID = candidate.session.id
        beginPreparing(lease)
        guard connection.show(ReaderExternalSurface(
            display: self, session: candidate.session, navigator: candidate.navigator, appModel: model, viewport: viewport
        ), interfaceStyle: candidate.interfaceStyle) else {
            fail(lease.generation)
            return nil
        }
        pointer.targets.window = connection.window
        return nil
    }

    private func updateDeviceAdmission(awaitingAccessory: Candidate?) {
        for (id, owner) in candidates {
            guard owner !== lease?.owner, !owner.session.permitsDeviceReader, !owner.session.isClosed,
                  owner.session.contentID == owner.contentID else {
                owner.cancelDeviceAdmissionWait()
                continue
            }
            if let phase = scenePhases[id], phase != .active {
                owner.cancelDeviceAdmissionWait()
                continue
            }
            let awaitingRegistration: Bool
            if #available(iOS 27, *) {
                awaitingRegistration = owner.host == nil
            } else {
                awaitingRegistration = false
            }
            let awaitingWindow = isTakeoverEnabled && lease == nil && !needsExplicitActivation && awaitingAccessory == nil &&
                (scenePhases[id] == nil || awaitingRegistration)
            if hasLoadedTakeoverSettings && owner !== awaitingAccessory && !awaitingWindow {
                owner.cancelDeviceAdmissionWait()
                owner.session.permitDeviceReader()
            } else if owner.deviceAdmissionWait == nil {
                // Bound the entire selection, including a missing host, not
                // just a registered accessory waiting for its external scene.
                owner.deviceAdmissionWait = Task { [weak self, weak owner] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, let owner, candidates[id] === owner, owner !== lease?.owner,
                          owner.session.contentID == owner.contentID else { return }
                    owner.session.permitDeviceReader()
                    evaluate()
                }
            }
        }
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
        lease.viewport.didFailInitialPresentation = { [weak self] in self?.fail(generation) }
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
        lease.viewport.didFailInitialPresentation = nil
        lease.owner.session.endNovelViewportPreparation(for: lease.viewport)
        lease.viewport.finishPreparationTrace("first-frame")
        let hasDeviceInteraction = lease.owner.session.deviceInteraction != nil
        setPhase(hasDeviceInteraction ? .deviceInteraction : .external)
        lease.connection.conceal(!showsReaderOnExternalDisplay)
    }

    private func fail(_ generation: UUID) {
        guard let lease, lease.generation == generation, phase == .preparing,
              !lease.owner.session.isClosed, lease.owner.session.contentID == lease.owner.contentID else { return }
        YamiboLog.reader.info("External reader preparation did not complete; restoring the device viewport")
        lease.owner.model?.externalDisplayFailure = true
        failedPresentation = lease.connection.sceneIdentifier.map {
            FailedPresentation(sceneID: $0, contentID: lease.owner.contentID)
        }
        reservedOwner = nil
        release(requireActivation: false)
    }

    private func release(requireActivation: Bool, permitsDeviceReader: Bool = true) {
        needsExplicitActivation = requireActivation
        guard let lease else { return }
        lease.viewport.finishPreparationTrace("released")
        self.lease = nil
        sessionID = nil
        timeout?.cancel()
        timeout = nil
        setPhase(.local)
        lease.connection.conceal(true)
        if !lease.owner.session.isClosed, lease.owner.session.contentID == lease.owner.contentID {
            lease.owner.session.returnToDeviceViewport()
            if permitsDeviceReader { lease.owner.session.permitDeviceReader() }
        }
        lease.connection.retireWindow()
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        if phase != .external { isDeviceMenuPresented = false }
        if !isWaitingForExternalFrame { deviceFrameDuringPreparation = nil }
        synchronizeInput()
        if phase == .local { pointer.reset() }
    }

    private func synchronizeInput(revealCursor: Bool = true) {
        // Invalidate in-flight gestures before an overlay can consume input.
        pointer.setEnabled(canUseTrackpad, revealCursor: revealCursor)
        lease?.viewport.setInputPaused(!canUseTrackpad)
        wakefulness.setNeeded(phase == .external && showsReaderOnExternalDisplay)
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

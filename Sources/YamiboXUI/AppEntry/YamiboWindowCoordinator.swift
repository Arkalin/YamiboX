import Observation
import SwiftUI
import UIKit
import YamiboXCore

public struct YamiboWindowRequest: Codable, Hashable, Sendable {
    public let id: UUID
    public let readerRoute: ReaderResumeRoute?
    public let forumURL: URL?

    public init(readerRoute: ReaderResumeRoute? = nil, forumURL: URL? = nil) {
        id = UUID()
        self.readerRoute = readerRoute
        self.forumURL = forumURL
    }
}

/// Process-wide services live here; navigation and reading sessions live in each model.
@MainActor
@Observable
public final class YamiboWindowCoordinator {
    public let appContext: YamiboAppContext
    public let webSessionCoordinator: ForumWebSessionCoordinator
    public let imagePipeline: YamiboUIImagePipeline
    public private(set) var presentationWindowID: String?
    private(set) var focusedWindowID: String?
    private(set) var aggregatePhase: ScenePhase = .background

    @ObservationIgnored let synchronization: AppContinuityWorkflow
    @ObservationIgnored private let runtime: AppRuntimeCoordinator
    @ObservationIgnored private let restorationDefaults: UserDefaults
    @ObservationIgnored private var models: [String: WeakModel] = [:]
    @ObservationIgnored private var phases: [String: ScenePhase] = [:]
    @ObservationIgnored private var sceneIdentifiers: [String: String] = [:]
    @ObservationIgnored private var bootstrapTask: Task<AppContinuityLaunchResult, Never>?
    @ObservationIgnored private var accountEpoch = UUID()
    @ObservationIgnored private var legacyResumeRoute: ReaderResumeRoute?
    @ObservationIgnored private var legacyWindowID: String?
    @ObservationIgnored private var pendingSearchSceneID: String?
    @ObservationIgnored private var hasPendingSearch = false
    @ObservationIgnored private var pendingNotificationUserInfo: [AnyHashable: Any]?

    private static let restorationPrefix = "yamibox.window.resumeRoute."

    public init(
        appContext: YamiboAppContext,
        webSessionCoordinator: ForumWebSessionCoordinator? = nil,
        imagePipeline: YamiboUIImagePipeline? = nil,
        restorationDefaults: UserDefaults = .standard
    ) {
        self.appContext = appContext
        self.webSessionCoordinator = webSessionCoordinator ?? ForumWebSessionCoordinator(
            sessionStore: appContext.forumDependencies.sessionStore
        )
        self.imagePipeline = imagePipeline ?? YamiboUIImagePipeline(core: appContext.imagePipeline)
        self.restorationDefaults = restorationDefaults
        let synchronization = AppContinuityWorkflow(appContext: appContext)
        self.synchronization = synchronization
        runtime = appContext.makeRuntimeCoordinator(continuity: synchronization)
    }

    public func startRuntime() { runtime.start() }

    func stopRuntime() { runtime.stop() }

    public func makeModel(windowID: String, initialTab: AppTab = .forum) -> YamiboAppModel {
        if let model = models[windowID]?.value { return model }
        let model = YamiboAppModel(
            appContext: appContext,
            initialTab: initialTab,
            webSessionCoordinator: webSessionCoordinator,
            imagePipeline: imagePipeline,
            windowCoordinator: self,
            windowID: windowID,
            readerResumeRouteStore: resumeRouteStore(windowID: windowID)
        )
        models[windowID] = WeakModel(model)
        if legacyWindowID == nil { legacyWindowID = windowID }
        if presentationWindowID == nil { presentationWindowID = windowID }
        if let userInfo = pendingNotificationUserInfo {
            pendingNotificationUserInfo = nil
            Task { await FavoriteUpdateNotificationRouting.open(notificationUserInfo: userInfo, appModel: model) }
        }
        return model
    }

    func resumeRouteStore(windowID: String) -> ReaderResumeRouteStore {
        ReaderResumeRouteStore(defaults: restorationDefaults, key: Self.restorationPrefix + windowID)
    }

    func bootstrap(
        onProgress: @escaping @Sendable (AppBootstrapPhase) async -> Void
    ) async -> AppContinuityLaunchResult {
        if let bootstrapTask { return await bootstrapTask.value }
        let epoch = accountEpoch
        let task = Task { [self] in
            await configureAccountTransitions()
            let result = await synchronization.launchIfNeeded(canRestoreReaderRoute: true, onProgress: onProgress)
            guard epoch == accountEpoch else {
                return AppContinuityLaunchResult(bootstrapState: await appContext.bootstrap(), restoredRoute: nil)
            }
            legacyResumeRoute = result.restoredRoute
            return result
        }
        bootstrapTask = task
        return await task.value
    }

    func claimLegacyResumeRoute(windowID: String?) -> ReaderResumeRoute? {
        guard windowID == legacyWindowID else { return nil }
        defer {
            legacyResumeRoute = nil
            synchronization.readerRouteDismissed()
        }
        return legacyResumeRoute
    }

    @discardableResult
    func scenePhaseDidChange(_ phase: ScenePhase, windowID: String) -> Bool {
        guard phases[windowID] != phase else { return false }
        phases[windowID] = phase
        updateAggregatePhase()
        if phase != .active, focusedWindowID == windowID { focusedWindowID = nil }
        if presentationWindowID == nil || phases[presentationWindowID ?? ""] != .active {
            presentationWindowID = phases.first(where: { $0.value == .active })?.key ?? presentationWindowID
        }
        return true
    }

    private func updateAggregatePhase() {
        let phase: ScenePhase = phases.values.contains(.active) ? .active
            : phases.values.contains(.inactive) ? .inactive : .background
        aggregatePhase = phase
        let runtimePhase: AppRuntimePhase = phase == .active ? .active : phase == .inactive ? .inactive : .background
        guard runtime.transition(to: runtimePhase) else { return }
        webSessionCoordinator.setAppIsActive(phase == .active)
        #if canImport(BackgroundTasks)
        if phase == .background {
            FavoriteUpdateBackgroundScheduler.scheduleNextIfNeeded(appContext: appContext)
        }
        #endif
    }

    func bind(window: UIWindow, windowID: String) {
        guard let scene = window.windowScene else { return }
        bind(sceneIdentifier: scene.session.persistentIdentifier, windowID: windowID)
    }

    func bind(sceneIdentifier: String, windowID: String) {
        sceneIdentifiers[sceneIdentifier] = windowID
        if hasPendingSearch, pendingSearchSceneID == nil || pendingSearchSceneID == sceneIdentifier {
            hasPendingSearch = false
            pendingSearchSceneID = nil
            models[windowID]?.value?.openForumSearch()
        }
    }

    /// Called by UIKit key-window notifications and actual events, never by view appearance.
    func focus(windowID: String) {
        guard models[windowID]?.value != nil else { return }
        if focusedWindowID != windowID {
            for model in liveModels { model.peripheralInput.resetPressState() }
        }
        focusedWindowID = windowID
        presentationWindowID = Self.presentationOwner(
            current: presentationWindowID,
            focused: windowID,
            hasPresentation: webSessionCoordinator.presentation != nil,
            currentOwnerIsActive: phases[presentationWindowID ?? ""] == .active
        )
    }

    static func presentationOwner(current: String?, focused: String, hasPresentation: Bool, currentOwnerIsActive: Bool) -> String {
        if let current, hasPresentation, currentOwnerIsActive { return current }
        return focused
    }

    func acceptsPeripheralInput(windowID: String) -> Bool {
        guard phases[windowID] == .active else { return false }
        if let focusedWindowID { return focusedWindowID == windowID }
        let activeIDs = phases.filter { $0.value == .active }.map(\.key)
        return activeIDs.count == 1 && activeIDs.first == windowID
    }

    public func sceneDidDisconnect(_ sceneIdentifier: String) {
        guard let windowID = sceneIdentifiers.removeValue(forKey: sceneIdentifier) else { return }
        phases.removeValue(forKey: windowID)
        if focusedWindowID == windowID { focusedWindowID = nil }
        if presentationWindowID == windowID {
            presentationWindowID = phases.first(where: { $0.value == .active })?.key
        }
        updateAggregatePhase()
    }

    public func openForumSearch(sceneIdentifier: String? = nil) {
        let windowID: String?
        if let sceneIdentifier {
            windowID = sceneIdentifiers[sceneIdentifier]
        } else {
            windowID = focusedWindowID ?? presentationWindowID
        }
        if let windowID, let model = models[windowID]?.value {
            model.openForumSearch()
        } else {
            hasPendingSearch = true
            pendingSearchSceneID = sceneIdentifier
        }
    }

    public func openNotification(userInfo: [AnyHashable: Any]) async {
        if let windowID = focusedWindowID ?? presentationWindowID, let model = models[windowID]?.value {
            await FavoriteUpdateNotificationRouting.open(notificationUserInfo: userInfo, appModel: model)
        } else {
            pendingNotificationUserInfo = userInfo
        }
    }

    private func configureAccountTransitions() async {
        await appContext.accountTransitionLifecycle.configure(
            preserveLocalEdits: { [appContext] in
                try await ForumComposerDraftCoordinator.prepareForAccountChange(sessionStore: appContext.accountDependencies.sessionStore)
            },
            prepare: { [weak self] in
                guard let self else { return }
                for model in liveModels { model.cancelMangaReaderOpen() }
                await webSessionCoordinator.prepareForAccountChange()
                await IOSForumWebView.Coordinator.prepareForAccountChange(sessionStore: appContext.accountDependencies.sessionStore)
                await FavoriteRemoteSyncSession.cancelForAccountChange(libraryStore: appContext.localFavoriteLibraryStore)
            },
            finish: { [weak self] session in
                guard let self else { return }
                ForumComposerDraftCoordinator.finishAccountChange(sessionStore: appContext.accountDependencies.sessionStore)
                await webSessionCoordinator.finishAccountChange(session)
                await IOSForumWebView.Coordinator.finishAccountChange(session, sessionStore: appContext.accountDependencies.sessionStore)
            },
            publish: { [weak self] in self?.publishAccountChange() }
        )
    }

    func publishAccountChange() {
        accountEpoch = UUID()
        bootstrapTask = nil
        for model in liveModels { model.publishAccountChange() }
        // Include disconnected scenes so reopening one cannot restore the previous account.
        for key in restorationDefaults.dictionaryRepresentation().keys where key.hasPrefix(Self.restorationPrefix) {
            restorationDefaults.removeObject(forKey: key)
        }
        legacyResumeRoute = nil
        synchronization.readerRouteDismissed()
    }

    private var liveModels: [YamiboAppModel] {
        models = models.filter { $0.value.value != nil }
        return models.values.compactMap(\.value)
    }

    private final class WeakModel {
        weak var value: YamiboAppModel?
        init(_ value: YamiboAppModel) { self.value = value }
    }
}

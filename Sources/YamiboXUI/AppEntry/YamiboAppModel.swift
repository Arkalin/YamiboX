import Foundation
import Observation
import SwiftUI
import YamiboXCore

public struct ForumNavigationRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let url: URL
    public let source: ForumNavigationSource
    public let title: String?

    public init(url: URL, source: ForumNavigationSource = .external, title: String? = nil) {
        self.url = url
        self.source = source
        self.title = title
    }
}

public struct ClipboardForumLinkPrompt: Identifiable, Equatable, Sendable {
    public let url: URL

    public var id: String { url.absoluteString }

    public init(url: URL) {
        self.url = url
    }
}

public struct ForumSearchRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()

    public init() {}
}

@MainActor
@Observable
public final class YamiboAppModel {
    public private(set) var bootstrapState: YamiboBootstrapState?
    public private(set) var isBootstrapping = false
    public private(set) var bootstrapPhase: AppBootstrapPhase?
    public var bootstrapErrorMessage: String?
    public private(set) var selectedTab: AppTab
    public var activeNovelContext: NovelLaunchContext? {
        guard case let .novel(context) = currentReaderSession?.resumeRoute else { return nil }
        return context
    }
    public var activeMangaContext: MangaLaunchContext? {
        guard case let .manga(context) = currentReaderSession?.resumeRoute else { return nil }
        return context
    }
    private(set) var presentedReaderSession: ReaderSession?
    // Remains true until the closing animation finishes, not just until close().
    private(set) var isReaderCoverVisible = false
    private(set) var isOpeningMangaReader = false
    var mangaOpenFailure: LoadFailureDetails?
    @ObservationIgnored let mangaReaderOpenValidator: MangaReaderOpenValidator
    @ObservationIgnored private var mangaOpenTask: Task<Void, Never>?
    @ObservationIgnored private var mangaOpenRequestID: UUID?
    public private(set) var suspendedNovelContext: NovelLaunchContext?
    public private(set) var suspendedMangaContext: MangaLaunchContext?
    public private(set) var forumNavigationRequest: ForumNavigationRequest?
    public private(set) var forumSearchRequest: ForumSearchRequest?
    @ObservationIgnored private var claimedForumNavigationRequestID: UUID?
    @ObservationIgnored private var claimedForumSearchRequestID: UUID?
    public private(set) var appThemePreset = AppThemePreset.classic
    public var clipboardForumLinkPrompt: ClipboardForumLinkPrompt?
    let forumContentRefresh = ForumContentRefreshState()

    public let appContext: YamiboAppContext
    public let imagePipeline: YamiboUIImagePipeline
    public let peripheralInput: ReaderPeripheralInputManager
    public let webSessionCoordinator: ForumWebSessionCoordinator
    public private(set) var accountGeneration = UUID()
    public let windowID: String?
    public var ownsWebSessionPresentation: Bool {
        guard let windowCoordinator, let windowID else { return true }
        return windowCoordinator.presentationWindowID == windowID
    }

    @ObservationIgnored private let appContinuity: AppContinuityWorkflow
    @ObservationIgnored private let runtime: AppRuntimeCoordinator?
    @ObservationIgnored private weak var windowCoordinator: YamiboWindowCoordinator?
    @ObservationIgnored private var settingsObservationTask: Task<Void, Never>?
    private weak var currentReaderSession: ReaderSession?

    public init(
        appContext: YamiboAppContext,
        initialTab: AppTab = .forum,
        webSessionCoordinator: ForumWebSessionCoordinator? = nil,
        imagePipeline: YamiboUIImagePipeline? = nil,
        mangaReaderOpenValidator: MangaReaderOpenValidator? = nil,
        windowCoordinator: YamiboWindowCoordinator? = nil,
        windowID: String? = nil,
        readerResumeRouteStore: ReaderResumeRouteStore? = nil
    ) {
        self.appContext = appContext
        self.imagePipeline = imagePipeline ?? YamiboUIImagePipeline(core: appContext.imagePipeline)
        self.mangaReaderOpenValidator = mangaReaderOpenValidator ?? MangaReaderOpenValidator { request in
            let loader = await appContext.mangaReaderDependencies.makeProjectionLoader()
            return try await loader.loadReaderProjection(request)
        }
        selectedTab = initialTab
        self.windowCoordinator = windowCoordinator
        self.windowID = windowID
        let continuity = AppContinuityWorkflow(appContext: appContext, readerResumeRouteStore: readerResumeRouteStore)
        appContinuity = continuity
        runtime = windowCoordinator == nil ? appContext.makeRuntimeCoordinator(continuity: continuity) : nil
        peripheralInput = ReaderPeripheralInputManager(
            settingsStore: appContext.settingsStore,
            usesWindowKeyboardEvents: windowCoordinator != nil,
            acceptsInput: { [weak windowCoordinator] in
                guard let windowID else { return true }
                return windowCoordinator?.acceptsPeripheralInput(windowID: windowID) == true
            }
        )
        self.webSessionCoordinator = webSessionCoordinator ?? ForumWebSessionCoordinator(
            sessionStore: appContext.forumDependencies.sessionStore
        )
        observeAppAppearanceSettings()
    }

    deinit {
        settingsObservationTask?.cancel()
        mangaOpenTask?.cancel()
    }

    /// Called once by the app entry point, not by a view's task or appearance.
    public func startRuntime() {
        if let windowCoordinator { windowCoordinator.startRuntime() } else { runtime?.start() }
    }

    func stopRuntime() {
        runtime?.stop()
    }

    @discardableResult
    func scenePhaseDidChange(_ phase: ScenePhase) -> Bool {
        if let windowCoordinator, let windowID {
            return windowCoordinator.scenePhaseDidChange(phase, windowID: windowID)
        }
        let runtimePhase: AppRuntimePhase
        switch phase {
        case .active: runtimePhase = .active
        case .inactive: runtimePhase = .inactive
        case .background: runtimePhase = .background
        @unknown default: return false
        }
        guard runtime?.transition(to: runtimePhase) == true else { return false }
        webSessionCoordinator.setAppIsActive(phase == .active)
#if os(iOS) && canImport(BackgroundTasks)
        if phase == .background {
            FavoriteUpdateBackgroundScheduler.scheduleNextIfNeeded(appContext: appContext)
        }
#endif
        return true
    }

    public func bootstrapIfNeeded() async {
        guard bootstrapState == nil, !isBootstrapping else { return }
        let generation = accountGeneration
        isBootstrapping = true
        defer {
            isBootstrapping = false
            bootstrapPhase = nil
        }

        let result: AppContinuityLaunchResult
        if let windowCoordinator {
            let shared = await windowCoordinator.bootstrap(onProgress: updateBootstrapPhase)
            let route = await appContinuity.restoreExplicitly(
                canRestoreReaderRoute: canRestoreReaderRoute,
                onProgress: updateBootstrapPhase
            )
            let legacyRoute = windowCoordinator.claimLegacyResumeRoute(windowID: windowID)
            result = AppContinuityLaunchResult(
                bootstrapState: shared.bootstrapState,
                restoredRoute: route ?? legacyRoute
            )
        } else {
            await configureAccountTransitions()
            result = await appContinuity.launchIfNeeded(
                canRestoreReaderRoute: canRestoreReaderRoute,
                onProgress: updateBootstrapPhase
            )
        }
        let state = generation == accountGeneration ? result.bootstrapState : await appContext.bootstrap()
        appThemePreset = state.settings.appearance.themePreset
        bootstrapState = state
        bootstrapErrorMessage = nil
        if generation == accountGeneration { applyRestoredRoute(result.restoredRoute) }
    }

    private func configureAccountTransitions() async {
        await appContext.accountTransitionLifecycle.configure(
            preserveLocalEdits: { [weak self] in
                guard let self else { return }
                try await ForumComposerDraftCoordinator.prepareForAccountChange(sessionStore: appContext.accountDependencies.sessionStore)
            },
            prepare: { [weak self] in
                guard let self else { return }
                cancelMangaReaderOpen()
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
            publish: { [weak self] in
                self?.publishAccountChange()
            }
        )
    }

    func publishAccountChange() {
        cancelMangaReaderOpen()
        suspendedNovelContext = nil
        suspendedMangaContext = nil
        forumNavigationRequest = nil
        forumSearchRequest = nil
        claimedForumNavigationRequestID = nil
        claimedForumSearchRequestID = nil
        clipboardForumLinkPrompt = nil
        forumContentRefresh.reset()
        (currentReaderSession ?? presentedReaderSession)?.close()
        appContinuity.readerRouteDismissed()
        accountGeneration = UUID()
    }

    public func bootstrap() async {
        let generation = accountGeneration
        isBootstrapping = true
        defer {
            isBootstrapping = false
            bootstrapPhase = nil
        }

        let state = await appContext.bootstrap(onProgress: updateBootstrapPhase)
        appThemePreset = state.settings.appearance.themePreset
        bootstrapState = state
        bootstrapErrorMessage = nil
        let restoredRoute = await appContinuity.restoreExplicitly(
            canRestoreReaderRoute: canRestoreReaderRoute,
            onProgress: updateBootstrapPhase
        )
        if generation == accountGeneration { applyRestoredRoute(restoredRoute) }
    }

    private func updateBootstrapPhase(_ phase: AppBootstrapPhase) async {
        bootstrapPhase = phase
    }

    public func synchronizeWebDAVIfNeeded() {
        synchronization.foregroundBecameActive()
    }

    public var hasActiveReaderPresentation: Bool {
        presentedReaderSession != nil || activeNovelContext != nil || activeMangaContext != nil
    }

    public func scheduleWebDAVUploadForLocalChange(touchesAppSettings: Bool = false) {
        synchronization.localDataChanged(touchesAppSettings: touchesAppSettings)
    }

    public func scheduleWebDAVUploadForReadingProgressChange() {
        synchronization.localDataChanged()
    }

    public func flushWebDAVSyncBeforeBackground() {
        synchronization.willEnterBackground()
    }

    private var synchronization: AppContinuityWorkflow {
        windowCoordinator?.synchronization ?? appContinuity
    }

    public func refreshAppAppearanceSettings() async {
        let settings = await appContext.settingsStore.load()
        appThemePreset = settings.appearance.themePreset
    }

    private func observeAppAppearanceSettings() {
        let settingsStore = appContext.settingsStore
        settingsObservationTask = Task { [weak self] in
            for await changeID in settingsStore.changes() {
                guard !Task.isCancelled else { return }
                guard changeID == settingsStore.changeID else { continue }
                guard let self else { return }
                await self.refreshAppAppearanceSettings()
            }
        }
    }

    public func presentNovelReader(_ context: NovelLaunchContext) {
        presentNovelReader(context, bookOpeningTransition: nil)
    }

    func presentNovelReader(_ context: NovelLaunchContext, bookOpeningTransition: BookOpeningTransition?) {
        cancelMangaReaderOpen()
        suspendedNovelContext = nil
        presentReaderContent(.novel(context), bookOpeningTransition: bookOpeningTransition)
    }

    public func selectTab(_ tab: AppTab) {
        if tab != selectedTab { cancelMangaReaderOpen() }
        selectedTab = tab
        restoreSuspendedNovelIfNeeded(for: tab)
        restoreSuspendedMangaIfNeeded(for: tab)
    }

    /// Low-level presentation for validated launches and existing resume routes.
    public func presentMangaReader(_ context: MangaLaunchContext, initialProjection: MangaReaderProjection? = nil) {
        presentMangaReader(context, initialProjection: initialProjection, bookOpeningTransition: nil)
    }

    private func presentMangaReader(
        _ context: MangaLaunchContext,
        initialProjection: MangaReaderProjection?,
        bookOpeningTransition: BookOpeningTransition?
    ) {
        cancelMangaReaderOpen()
        suspendedMangaContext = nil
        presentReaderContent(.manga(context), mangaProjection: initialProjection, bookOpeningTransition: bookOpeningTransition)
    }

    /// User-initiated opens validate on the source page before creating a reader.
    @discardableResult
    public func requestMangaReader(_ context: MangaLaunchContext) -> Task<Void, Never> {
        requestMangaReader(context, bookOpeningTransition: nil)
    }

    @discardableResult
    func requestMangaReader(_ context: MangaLaunchContext, bookOpeningTransition: BookOpeningTransition?) -> Task<Void, Never> {
        if let session = presentedReaderSession ?? currentReaderSession,
           session.presentation == .fullScreen, !session.isClosed {
            return Task { await session.openMangaReader(context) }
        }
        if let mangaOpenTask { return mangaOpenTask }
        if currentReaderSession?.presentation == .embeddedThread {
            currentReaderSession?.cancelSwitch()
        }
        let requestID = UUID()
        mangaOpenRequestID = requestID
        isOpeningMangaReader = true
        mangaOpenFailure = nil
        let validator = mangaReaderOpenValidator
        let task = Task { [weak self] in
            do {
                let projection = try await validator.validate(context)
                guard let self, !Task.isCancelled, self.mangaOpenRequestID == requestID else { return }
                self.presentMangaReader(context, initialProjection: projection, bookOpeningTransition: bookOpeningTransition)
            } catch {
                guard let self, !Task.isCancelled, self.mangaOpenRequestID == requestID else { return }
                if !LoadDiagnosticError.isCancellation(error) {
                    self.mangaOpenFailure = LoadFailureDetails(error: error)
                }
                self.cancelMangaReaderOpen()
            }
        }
        mangaOpenTask = task
        return task
    }

    func cancelMangaReaderOpen() {
        mangaOpenRequestID = nil
        mangaOpenTask?.cancel()
        mangaOpenTask = nil
        isOpeningMangaReader = false
    }

    private func presentReaderContent(
        _ content: ReaderSessionContent,
        mangaProjection: MangaReaderProjection? = nil,
        bookOpeningTransition: BookOpeningTransition? = nil
    ) {
        let activeFullScreenSession = currentReaderSession.flatMap {
            $0.presentation == .fullScreen ? $0 : nil
        }
        if currentReaderSession?.presentation == .embeddedThread {
            currentReaderSession?.prepareForContentPresentation()
        }
        if let session = presentedReaderSession ?? activeFullScreenSession, !session.isClosed {
            session.present(content, mangaProjection: mangaProjection)
        } else {
            let session = makeReaderSession(content: content, bookOpeningTransition: bookOpeningTransition)
            isReaderCoverVisible = true
            presentedReaderSession = session
            session.present(content, mangaProjection: mangaProjection)
        }
    }

    func makeReaderSession(
        content: ReaderSessionContent,
        bookOpeningTransition: BookOpeningTransition? = nil,
        presentation: ReaderSessionPresentation = .fullScreen
    ) -> ReaderSession {
        ReaderSession(
            content: content,
            dependencies: ReaderSessionDependencies(
                forum: appContext.forumDependencies,
                mangaReaderOpenValidator: mangaReaderOpenValidator
            ),
            lifecycle: ReaderSessionLifecycle(
                didActivate: { [weak self] session, previousRoute in
                    self?.activateReaderSession(session, previousRoute: previousRoute)
                },
                didUpdateResumeRoute: { [weak self] session, route in
                    self?.updateReaderSessionResumeRoute(route, session: session)
                },
                didDeactivate: { [weak self] session in self?.deactivateReaderSession(session) },
                didClose: { [weak self] session in self?.finishReaderSession(session) },
                didRequestFullScreen: { [weak self] session, content, projection in
                    guard let self, self.currentReaderSession === session,
                          self.presentedReaderSession == nil, !session.isClosed else { return }
                    self.isReaderCoverVisible = true
                    self.presentedReaderSession = session
                    session.promoteToFullScreen(content, mangaProjection: projection)
                }
            ),
            bookOpeningTransition: bookOpeningTransition,
            presentation: presentation
        )
    }

    private func activateReaderSession(_ session: ReaderSession, previousRoute: ReaderResumeRoute?) {
        if session.presentation == .embeddedThread, presentedReaderSession != nil { return }
        let hadReader = currentReaderSession?.resumeRoute != nil ||
            (currentReaderSession === session && previousRoute != nil)
        currentReaderSession = session
        switch session.resumeRoute {
        case let .novel(context):
            guard !context.isPreview else { return }
            appContinuity.readerRoutePresented(.novel(context))
        case let .manga(context):
            guard !context.isPreview else { return }
            appContinuity.readerRoutePresented(.manga(context))
        case nil:
            if hadReader { appContinuity.readerRouteDismissed() }
        }
    }

    private func updateReaderSessionResumeRoute(_ route: ReaderResumeRoute, session: ReaderSession) {
        guard currentReaderSession === session else { return }
        appContinuity.readerReadingPositionChanged(route)
    }

    private func deactivateReaderSession(_ session: ReaderSession) {
        guard currentReaderSession === session else { return }
        currentReaderSession = nil
        appContinuity.readerRouteDismissed()
    }

    private func finishReaderSession(_ session: ReaderSession) {
        deactivateReaderSession(session)
        if presentedReaderSession === session { presentedReaderSession = nil }
    }

    func dismissPresentedReaderSession() {
        presentedReaderSession?.close()
    }

    func readerCoverDidDismiss() {
        guard presentedReaderSession == nil else { return }
        isReaderCoverVisible = false
    }

    func switchReaderToOriginalPost(url: URL, resumeRoute: ReaderResumeRoute) async -> Bool {
        await (currentReaderSession ?? presentedReaderSession)?.openOriginalPost(url: url, resumeRoute: resumeRoute) ?? false
    }

    public func dismissNovelReader(
        openThreadInForum url: URL? = nil,
        suspendedNovelContext: NovelLaunchContext? = nil,
        forumNavigationSource: ForumNavigationSource = .readerDiscussion
    ) {
        if url != nil {
            self.suspendedNovelContext = suspendedNovelContext ?? activeNovelContext
        } else {
            self.suspendedNovelContext = nil
        }
        (currentReaderSession ?? presentedReaderSession)?.close()
        appContinuity.readerRouteDismissed()
        if let url {
            selectedTab = .forum
            forumNavigationRequest = ForumNavigationRequest(url: url, source: forumNavigationSource)
        }
    }

    public func dismissMangaReader(
        openThreadInForum url: URL? = nil,
        suspendedMangaContext: MangaLaunchContext? = nil,
        forumNavigationSource: ForumNavigationSource = .readerDiscussion
    ) {
        if url != nil {
            self.suspendedMangaContext = suspendedMangaContext ?? activeMangaContext
        } else if activeMangaContext != nil {
            self.suspendedMangaContext = nil
        }
        (currentReaderSession ?? presentedReaderSession)?.close()
        appContinuity.readerRouteDismissed()
        if let url {
            selectedTab = .forum
            forumNavigationRequest = ForumNavigationRequest(url: url, source: forumNavigationSource)
        }
    }

    public func openForumURL(_ url: URL) {
        cancelMangaReaderOpen()
        appContinuity.readerRouteDismissed()
        if activeNovelContext != nil {
            dismissNovelReader(openThreadInForum: url, forumNavigationSource: .external)
            return
        }

        if activeMangaContext != nil {
            dismissMangaReader(openThreadInForum: url, forumNavigationSource: .external)
            return
        }

        dismissPresentedReaderSession()
        selectedTab = .forum
        forumNavigationRequest = ForumNavigationRequest(url: url)
    }

    public func openNativeForumThread(url: URL, title: String?) {
        selectedTab = .forum
        forumNavigationRequest = ForumNavigationRequest(url: url, source: .readerOrigin, title: title)
    }

    /// Claim before starting navigation so remounting the host cannot replay
    /// the request. Keep the payload for the startup reader-restore guard.
    func claimForumNavigationRequest() -> ForumNavigationRequest? {
        guard let request = forumNavigationRequest,
              claimedForumNavigationRequestID != request.id else { return nil }
        claimedForumNavigationRequestID = request.id
        return request
    }

    func claimForumSearchRequest() -> ForumSearchRequest? {
        guard let request = forumSearchRequest,
              claimedForumSearchRequestID != request.id else { return nil }
        claimedForumSearchRequestID = request.id
        return request
    }

    public func openForumSearch() {
        cancelMangaReaderOpen()
        appContinuity.readerRouteDismissed()
        if activeNovelContext != nil {
            dismissNovelReader()
        } else if activeMangaContext != nil {
            dismissMangaReader()
        }
        dismissPresentedReaderSession()
        selectedTab = .forum
        forumSearchRequest = ForumSearchRequest()
    }

    public func presentClipboardForumLinkPrompt(url: URL) {
        clipboardForumLinkPrompt = ClipboardForumLinkPrompt(url: url)
    }

    public func dismissClipboardForumLinkPrompt() {
        clipboardForumLinkPrompt = nil
    }

    public func confirmClipboardForumLinkPrompt(_ prompt: ClipboardForumLinkPrompt) {
        clipboardForumLinkPrompt = nil
        openForumURL(prompt.url)
    }

    public func updateReaderResumeRoute(_ route: ReaderResumeRoute) {
        guard let session = currentReaderSession else { return }
        session.updateResumeRoute(route, contentID: session.contentID)
    }

    private var canRestoreReaderRoute: Bool {
        !hasActiveReaderPresentation && forumNavigationRequest == nil && forumSearchRequest == nil
    }

    private func applyRestoredRoute(_ route: ReaderResumeRoute?) {
        // Re-checked at apply time, not just when bootstrap sampled it: a
        // reader presented while bootstrap was still awaiting (e.g. from a
        // favorite-update notification tap on cold start) must not be
        // replaced by the restored resume route.
        guard let route, canRestoreReaderRoute else { return }
        switch route {
        case let .novel(context):
            presentNovelReader(context)
        case let .manga(context):
            presentMangaReader(context)
        }
    }

    private func restoreSuspendedNovelIfNeeded(for tab: AppTab) {
        guard tab == .favorites, let context = suspendedNovelContext else { return }
        suspendedNovelContext = nil
        presentNovelReader(context)
    }

    private func restoreSuspendedMangaIfNeeded(for tab: AppTab) {
        guard tab == .favorites, let context = suspendedMangaContext else { return }
        suspendedMangaContext = nil
        presentMangaReader(context)
    }
}

import Foundation
import Observation
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
    public var activeNovelContext: NovelLaunchContext?
    public var activeMangaContext: MangaLaunchContext?
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
    public private(set) var appThemePreset = AppThemePreset.classic
    public var clipboardForumLinkPrompt: ClipboardForumLinkPrompt?

    public let appContext: YamiboAppContext
    public let peripheralInput: ReaderPeripheralInputManager
    public let webSessionCoordinator: ForumWebSessionCoordinator

    @ObservationIgnored private let appContinuity: AppContinuityWorkflow
    @ObservationIgnored private var settingsObservationTask: Task<Void, Never>?
    @ObservationIgnored private weak var currentReaderSession: ReaderSession?

    public init(
        appContext: YamiboAppContext,
        initialTab: AppTab = .forum,
        webSessionCoordinator: ForumWebSessionCoordinator? = nil,
        mangaReaderOpenValidator: MangaReaderOpenValidator? = nil
    ) {
        self.appContext = appContext
        self.mangaReaderOpenValidator = mangaReaderOpenValidator ?? MangaReaderOpenValidator { request in
            let loader = await appContext.mangaReaderDependencies.makeProjectionLoader()
            return try await loader.loadReaderProjection(request)
        }
        selectedTab = initialTab
        appContinuity = AppContinuityWorkflow(appContext: appContext)
        peripheralInput = ReaderPeripheralInputManager(settingsStore: appContext.settingsStore)
        self.webSessionCoordinator = webSessionCoordinator ?? ForumWebSessionCoordinator(
            sessionStore: appContext.forumDependencies.sessionStore
        )
        observeAppAppearanceSettings()
    }

    deinit {
        settingsObservationTask?.cancel()
        mangaOpenTask?.cancel()
    }

    public func bootstrapIfNeeded() async {
        guard bootstrapState == nil, !isBootstrapping else { return }
        isBootstrapping = true
        defer {
            isBootstrapping = false
            bootstrapPhase = nil
        }

        let result = await appContinuity.launchIfNeeded(
            canRestoreReaderRoute: canRestoreReaderRoute,
            onProgress: updateBootstrapPhase
        )
        appThemePreset = result.bootstrapState.settings.appearance.themePreset
        bootstrapState = result.bootstrapState
        bootstrapErrorMessage = nil
        applyRestoredRoute(result.restoredRoute)
    }

    public func bootstrap() async {
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
        applyRestoredRoute(restoredRoute)
    }

    private func updateBootstrapPhase(_ phase: AppBootstrapPhase) async {
        bootstrapPhase = phase
    }

    public func synchronizeWebDAVIfNeeded() {
        appContinuity.foregroundBecameActive()
    }

    public var hasActiveReaderPresentation: Bool {
        presentedReaderSession != nil || activeNovelContext != nil || activeMangaContext != nil
    }

    public func scheduleWebDAVUploadForLocalChange(touchesAppSettings: Bool = false) {
        appContinuity.localDataChanged(touchesAppSettings: touchesAppSettings)
    }

    public func scheduleWebDAVUploadForReadingProgressChange() {
        appContinuity.localDataChanged()
    }

    public func flushWebDAVSyncBeforeBackground() {
        appContinuity.willEnterBackground()
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
        if let session = currentReaderSession ?? presentedReaderSession, !session.isClosed {
            return Task { await session.openMangaReader(context) }
        }
        if let mangaOpenTask { return mangaOpenTask }
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
        if let session = currentReaderSession ?? presentedReaderSession, !session.isClosed {
            session.present(content, mangaProjection: mangaProjection)
        } else {
            let session = ReaderSession(content: content, appModel: self, bookOpeningTransition: bookOpeningTransition)
            isReaderCoverVisible = true
            presentedReaderSession = session
            session.present(content, mangaProjection: mangaProjection)
        }
    }

    func activateReaderSession(_ session: ReaderSession, route: ReaderResumeRoute?) {
        currentReaderSession = session
        switch route {
        case let .novel(context):
            activeNovelContext = context
            activeMangaContext = nil
            guard !context.isPreview else { return }
            appContinuity.readerRoutePresented(.novel(context))
        case let .manga(context):
            activeNovelContext = nil
            activeMangaContext = context
            guard !context.isPreview else { return }
            appContinuity.readerRoutePresented(.manga(context))
        case nil:
            let hadReader = activeNovelContext != nil || activeMangaContext != nil
            activeNovelContext = nil
            activeMangaContext = nil
            if hadReader { appContinuity.readerRouteDismissed() }
        }
    }

    func updateReaderSessionResumeRoute(_ route: ReaderResumeRoute, session: ReaderSession) {
        guard currentReaderSession === session else { return }
        updateReaderResumeRoute(route)
    }

    func deactivateReaderSession(_ session: ReaderSession) {
        guard currentReaderSession === session else { return }
        currentReaderSession = nil
        activeNovelContext = nil
        activeMangaContext = nil
        appContinuity.readerRouteDismissed()
    }

    func finishReaderSession(_ session: ReaderSession) {
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
        activeNovelContext = nil
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
        activeMangaContext = nil
        (currentReaderSession ?? presentedReaderSession)?.close()
        appContinuity.readerRouteDismissed()
        if let url {
            selectedTab = .forum
            forumNavigationRequest = ForumNavigationRequest(url: url, source: forumNavigationSource)
        }
    }

    public func openForumURL(_ url: URL) {
        cancelMangaReaderOpen()
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

    public func openForumSearch() {
        cancelMangaReaderOpen()
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
        switch route {
        case let .novel(context):
            guard activeNovelContext != nil else { return }
            activeNovelContext = context
        case let .manga(context):
            guard activeMangaContext != nil else { return }
            activeMangaContext = context
        }
        appContinuity.readerReadingPositionChanged(route)
    }

    private var canRestoreReaderRoute: Bool {
        !hasActiveReaderPresentation
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

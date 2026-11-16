import Foundation
import Observation
import YamiboXCore

enum ReaderSessionContent {
    case novel(NovelLaunchContext)
    case manga(MangaLaunchContext)
    case thread(ThreadNovelLaunchContext)

    var resumeRoute: ReaderResumeRoute? {
        switch self {
        case let .novel(context): .novel(context)
        case let .manga(context): .manga(context)
        case .thread: nil
        }
    }
}

private struct ReaderSessionPreparedContent {
    let content: ReaderSessionContent
    var threadPage: ForumThreadPage? = nil
}

@MainActor
private final class NovelViewportPreparation {
    let viewport: ReaderViewportLifetime
    let contentID: UUID
    let onFailure: @MainActor () -> Void
    var settings: NovelReaderAppearanceSettings?
    var geometry: ReaderViewportGeometry?
    var task: Task<Void, Never>?
    var revision: UInt64 = 0

    init(viewport: ReaderViewportLifetime, contentID: UUID, onFailure: @escaping @MainActor () -> Void) {
        self.viewport = viewport
        self.contentID = contentID
        self.onFailure = onFailure
    }

    func cancelRequest() {
        revision &+= 1
        task?.cancel()
        task = nil
    }
}

struct ReaderSessionDependencies: Sendable {
    let forum: ForumDependencies
    let mangaReaderOpenValidator: MangaReaderOpenValidator
    let settingsStore: SettingsStore
}

enum ReaderSessionPresentation {
    case fullScreen
    case embeddedThread
}

@MainActor
struct ReaderSessionLifecycle {
    var didActivate: @MainActor (ReaderSession, ReaderResumeRoute?) -> Void = { _, _ in }
    var didUpdateResumeRoute: @MainActor (ReaderSession, ReaderResumeRoute) -> Void = { _, _ in }
    var didDeactivate: @MainActor (ReaderSession) -> Void = { _ in }
    var didClose: @MainActor (ReaderSession) -> Void = { _ in }
    var didRequestFullScreen: @MainActor (ReaderSession, ReaderSessionContent, MangaReaderProjection?) -> Void = { _, _, _ in }
    var makeNovelReader: @MainActor (NovelLaunchContext, @escaping ReaderResumeRouteChangeHandler) -> NovelReaderSessionState
    var makeMangaReader: @MainActor (MangaLaunchContext, MangaReaderProjection?, @escaping ReaderResumeRouteChangeHandler) -> MangaReaderSessionState
}

/// One navigation entry, with independently resumable reading modes.
@MainActor
@Observable
final class ReaderSession: Identifiable {
    let id = UUID()
    let bookOpeningTransition: BookOpeningTransition?
    private(set) var presentation: ReaderSessionPresentation
    private(set) var content: ReaderSessionContent
    private(set) var resumeRoute: ReaderResumeRoute?
    private(set) var contentID = UUID()
    private(set) var viewport = ReaderViewportLifetime()
    private(set) var externalViewport: ReaderViewportLifetime?
    private(set) var permitsDeviceReader = false
    private(set) var deviceViewportPreparationFailed = false
    private var preparingViewport: ReaderViewportLifetime?
    var deviceInteraction: ReaderDeviceInteraction?
    private(set) var isSwitching = false
    private(set) var switchingTitle = L10n.string("reader.switching")
    @ObservationIgnored private(set) var preparedMangaProjection: MangaReaderProjection?
    private(set) var isClosed = false
    var switchFailure: LoadFailureDetails?
    let isPreview: Bool

    @ObservationIgnored private let dependencies: ReaderSessionDependencies
    @ObservationIgnored private let lifecycle: ReaderSessionLifecycle
    @ObservationIgnored private var novelContexts: [String: NovelLaunchContext] = [:]
    @ObservationIgnored private var mangaContexts: [String: MangaLaunchContext] = [:]
    @ObservationIgnored private var threadModels: [String: ForumThreadReaderViewModel] = [:]
    @ObservationIgnored private var novelReader: NovelReaderSessionState?
    @ObservationIgnored private var mangaReader: MangaReaderSessionState?
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var novelViewportPreparation: NovelViewportPreparation?
    @ObservationIgnored private var onFullScreenHandoff: (@MainActor () -> Void)?

    init(
        content: ReaderSessionContent,
        dependencies: ReaderSessionDependencies,
        lifecycle: ReaderSessionLifecycle,
        bookOpeningTransition: BookOpeningTransition? = nil,
        presentation: ReaderSessionPresentation = .fullScreen
    ) {
        self.content = content
        resumeRoute = content.resumeRoute
        self.dependencies = dependencies
        self.lifecycle = lifecycle
        self.bookOpeningTransition = bookOpeningTransition
        self.presentation = presentation
        switch content {
        case let .novel(context): isPreview = context.isPreview
        case let .manga(context): isPreview = context.isPreview
        case .thread: isPreview = false
        }
        if let route = content.resumeRoute { remember(route) }
    }

    deinit {
        switchTask?.cancel()
        settingsTask?.cancel()
    }

    func activate() {
        guard !isClosed else { return }
        guard !isActive else { return }
        isActive = true
        if externalViewport == nil { observeSettings(for: viewport) }
        lifecycle.didActivate(self, resumeRoute)
    }

    func deactivate() {
        isActive = false
        cancelSwitch()
        lifecycle.didDeactivate(self)
    }

    func close(savingProgress: Bool = true) {
        guard !isClosed else { return }
        completeFullScreenHandoff()
        cancelSwitch()
        retireReader(savingProgress: savingProgress)
        isClosed = true
        lifecycle.didClose(self)
    }

    func present(_ content: ReaderSessionContent, mangaProjection: MangaReaderProjection? = nil,
                 savingPreviousPosition: Bool = true) {
        guard !isClosed else { return }
        let previousRoute = resumeRoute
        // Transfer this session out of the navigation column, including its
        // cached thread model and independently resumable reading modes.
        if presentation == .embeddedThread, content.resumeRoute != nil {
            cancelSwitch()
            lifecycle.didRequestFullScreen(self, content, mangaProjection)
            return
        }
        prepareForContentPresentation()
        retireReader(savingProgress: savingPreviousPosition)
        self.content = content
        resumeRoute = content.resumeRoute
        preparedMangaProjection = mangaProjection
        contentID = UUID()
        viewport = ReaderViewportLifetime()
        permitsDeviceReader = false
        if let route = content.resumeRoute { remember(route) }
        isActive = true
        observeSettings(for: viewport)
        lifecycle.didActivate(self, previousRoute)
    }

    func promoteToFullScreen(_ content: ReaderSessionContent, mangaProjection: MangaReaderProjection?) {
        guard !isClosed, presentation == .embeddedThread else { return }
        presentation = .fullScreen
        present(content, mangaProjection: mangaProjection)
    }

    func completeFullScreenHandoff() {
        guard presentation == .fullScreen else { return }
        let completion = onFullScreenHandoff
        onFullScreenHandoff = nil
        completion?()
    }

    func prepareForContentPresentation() {
        cancelSwitch()
        if case let .thread(context) = content {
            threadModels[context.thread.tid]?.suspendForModeSwitch()
        }
    }

    func beginExternalViewport(
        resolution: ReaderSettingsTarget.Resolution,
        onTrackpadSensitivityChange: @escaping @MainActor (Double) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) -> ReaderViewportLifetime {
        endNovelViewportPreparation(for: viewport)
        viewport.retire(capturingPosition: true)
        permitsDeviceReader = false
        let next = ReaderViewportLifetime(settingsTarget: .external(resolution))
        externalViewport = next
        switch content {
        case let .novel(context):
            _ = novelReader(for: context)
            novelViewportPreparation = NovelViewportPreparation(viewport: next, contentID: contentID, onFailure: onFailure)
            next.admitsPresentationCallbacks = { [weak self, weak next] in
                guard let self, let next else { return false }
                return !self.isPreparingPresentation(for: next)
            }
        case let .manga(context):
            _ = mangaReader(for: context)
        case .thread:
            break
        }
        observeSettings(for: next, preparing: true,
                        onTrackpadSensitivityChange: onTrackpadSensitivityChange, onFailure: onFailure)
        return next
    }

    func returnToDeviceViewport() {
        guard let externalViewport else { return }
        endNovelViewportPreparation(for: externalViewport)
        externalViewport.retire(capturingPosition: true)
        novelReader?.model.resetInitialViewportPreparationIfNeeded()
        self.externalViewport = nil
        viewport = ReaderViewportLifetime()
        settingsTask?.cancel()
        preparingViewport = nil
    }

    func permitDeviceReader() {
        guard !permitsDeviceReader, externalViewport == nil, !isClosed else { return }
        permitsDeviceReader = true
        // A new session hasn't mounted a model yet. A returning reader uses
        // the same transaction as the external side, but with device geometry.
        guard novelReader != nil || mangaReader != nil else { return }
        let viewport = self.viewport
        if novelReader != nil {
            novelViewportPreparation = NovelViewportPreparation(viewport: viewport, contentID: contentID) { [weak self, weak viewport] in
                guard let self, let viewport, self.viewport === viewport else { return }
                deviceViewportPreparationFailed = true
            }
        }
        observeSettings(for: viewport, preparing: true)
    }

    var needsDeviceNovelGeometry: Bool {
        permitsDeviceReader && preparingViewport === viewport && novelViewportPreparation?.viewport === viewport
    }

    func retryDeviceViewportPreparation() {
        guard let preparation = novelViewportPreparation, preparation.viewport === viewport,
              deviceViewportPreparationFailed else { return }
        updateNovelViewportPreparation(preparation)
    }

    func isPreparingPresentation(for viewport: ReaderViewportLifetime) -> Bool {
        preparingViewport === viewport
    }

    func reportNovelViewportGeometry(_ geometry: ReaderViewportGeometry?, for viewport: ReaderViewportLifetime) {
        guard let preparation = novelViewportPreparation, preparation.viewport === viewport,
              preparation.geometry != geometry else { return }
        preparation.geometry = geometry
        if geometry != nil { viewport.tracePreparationStage("geometry-ready") }
        updateNovelViewportPreparation(preparation)
    }

    func endNovelViewportPreparation(for viewport: ReaderViewportLifetime) {
        guard let preparation = novelViewportPreparation, preparation.viewport === viewport else { return }
        preparation.cancelRequest()
        novelViewportPreparation = nil
        viewport.admitsPresentationCallbacks = nil
        deviceViewportPreparationFailed = false
    }

    private func updateNovelViewportPreparation(_ preparation: NovelViewportPreparation) {
        let viewport = preparation.viewport
        preparation.cancelRequest()
        viewport.invalidateFrameReport()
        preparingViewport = viewport
        deviceViewportPreparationFailed = false
        novelReader?.model.invalidateViewportSettingsUpdates()
        guard let settings = preparation.settings, let geometry = preparation.geometry else { return }
        guard let model = novelReader?.model else { preparation.onFailure(); return }
        model.resetInitialViewportPreparationIfNeeded()
        let revision = preparation.revision
        preparation.task = Task { [weak self, weak preparation] in
            defer {
                if preparation?.revision == revision { preparation?.task = nil }
            }
            guard let preparation, self?.ownsNovelViewportPreparation(preparation, revision: revision) == true else { return }
            do {
                let prepared = try await model.prepareNovelViewport(settings: settings, geometry: geometry, viewport: viewport)
                guard let self, ownsNovelViewportPreparation(preparation, revision: revision) else { return }
                guard prepared else { preparation.onFailure(); return }
                preparingViewport = nil
                if externalViewport !== viewport {
                    endNovelViewportPreparation(for: viewport)
                }
            } catch {
                guard let self, ownsNovelViewportPreparation(preparation, revision: revision) else { return }
                preparation.onFailure()
            }
        }
    }

    private func ownsNovelViewportPreparation(_ preparation: NovelViewportPreparation, revision: UInt64) -> Bool {
        !Task.isCancelled && !isClosed &&
            novelViewportPreparation === preparation && (externalViewport ?? viewport) === preparation.viewport &&
            preparation.viewport.isCurrent && contentID == preparation.contentID && preparation.revision == revision
    }

    private func observeSettings(
        for viewport: ReaderViewportLifetime,
        preparing: Bool = false,
        onTrackpadSensitivityChange: (@MainActor (Double) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) {
        settingsTask?.cancel()
        preparingViewport = nil
        guard content.resumeRoute != nil else { return }
        let store = dependencies.settingsStore
        let changes = store.changes()
        if preparing {
            preparingViewport = viewport
            novelReader?.model.invalidateViewportSettingsUpdates()
        }
        settingsTask = Task { [weak self] in
            if preparing {
                let snapshot: AppSettings
                do {
                    if case let .external(resolution) = viewport.settingsTarget {
                        snapshot = try await store.update { $0.initializeReaderProfile(for: resolution) }
                    } else {
                        snapshot = await store.load()
                    }
                } catch {
                    guard !Task.isCancelled, viewport.isCurrent else { return }
                    onFailure?()
                    return
                }
                let applied = await self?.applySettings(snapshot, to: viewport,
                                                        onTrackpadSensitivityChange: onTrackpadSensitivityChange) == true
                guard !Task.isCancelled, viewport.isCurrent else { return }
                if !applied, let onFailure {
                    onFailure()
                    return
                }
                if self?.novelViewportPreparation?.viewport !== viewport {
                    self?.preparingViewport = nil
                }
            }
            for await _ in changes {
                let snapshot = await store.load()
                guard !Task.isCancelled, viewport.isCurrent else { return }
                _ = await self?.applySettings(snapshot, to: viewport,
                                              onTrackpadSensitivityChange: onTrackpadSensitivityChange)
            }
        }
    }

    private func applySettings(
        _ settings: AppSettings, to viewport: ReaderViewportLifetime, onTrackpadSensitivityChange: (@MainActor (Double) -> Void)?
    ) async -> Bool {
        guard !Task.isCancelled, viewport.isCurrent, !isClosed else { return false }
        onTrackpadSensitivityChange?(settings.trackpadSensitivity(for: viewport.settingsTarget))
        if let preparation = novelViewportPreparation, preparation.viewport === viewport {
            let target = settings.novelSettings(for: viewport.settingsTarget)
            if preparation.settings != target {
                preparation.settings = target
                viewport.tracePreparationStage("settings-ready")
                updateNovelViewportPreparation(preparation)
            }
            return true
        }
        if let model = novelReader?.model {
            return await model.applyViewportSettings(settings.novelSettings(for: viewport.settingsTarget), viewport: viewport)
        }
        mangaReader?.model.applyViewportSettings(settings.mangaSettings(for: viewport.settingsTarget), target: viewport.settingsTarget)
        return true
    }

    func saveReadingPosition() {
        guard !isPreview else { return }
        (externalViewport ?? viewport).synchronizePosition()
        if let model = novelReader?.model, let route = model.resumeRouteForBackground() {
            updateResumeRoute(route, contentID: contentID)
            model.flushViewportSnapshot()
        } else if let model = mangaReader?.model, model.hasCurrentPage {
            updateResumeRoute(.manga(model.currentResumeContext), contentID: contentID)
            model.flushViewportSnapshot()
        }
    }

    func hideReaderChrome() {
        novelReader?.chromeState.hideChrome()
        mangaReader?.isChromeVisible = false
    }

    var isShowingDevicePanel: Bool {
        if let reader = novelReader {
            return reader.presentedSheet != nil || reader.searchPresentation != nil ||
                reader.forumThreadOverlayItem != nil || reader.imageBrowserItem != nil
        }
        if let reader = mangaReader {
            return reader.presentedPanel != nil ||
                reader.forumThreadOverlayItem != nil || reader.noteEditTarget != nil ||
                reader.imageSavePresentation.isActionDialogPresented || reader.isPhotoPermissionAlertPresented || reader.isSavingImage
        }
        return false
    }

    func updateResumeRoute(_ route: ReaderResumeRoute, contentID: UUID) {
        // Teardown saves from the previous mode must not replace the new route.
        guard !isClosed, !isPreview, self.contentID == contentID, acceptsResumeRoute(route) else { return }
        remember(route)
        resumeRoute = route
        lifecycle.didUpdateResumeRoute(self, route)
    }

    func novelReader(for context: NovelLaunchContext) -> NovelReaderSessionState {
        if let novelReader { return novelReader }
        let reader = lifecycle.makeNovelReader(context, routeReporter())
        novelReader = reader
        return reader
    }

    func mangaReader(for context: MangaLaunchContext) -> MangaReaderSessionState {
        if let mangaReader { return mangaReader }
        let reader = lifecycle.makeMangaReader(context, preparedMangaProjection, routeReporter())
        mangaReader = reader
        return reader
    }

    private func routeReporter() -> ReaderResumeRouteChangeHandler {
        { [weak self, contentID] route in
            self?.updateResumeRoute(route, contentID: contentID)
        }
    }

    @ObservationIgnored private var isActive = false

    private func retireReader(savingProgress: Bool) {
        deviceInteraction = nil
        settingsTask?.cancel()
        endNovelViewportPreparation(for: viewport)
        if let externalViewport { endNovelViewportPreparation(for: externalViewport) }
        preparingViewport = nil
        viewport.retire(capturingPosition: savingProgress)
        externalViewport?.retire(capturingPosition: savingProgress)
        externalViewport = nil
        novelReader?.end()
        novelReader?.model.finish(savingProgress: savingProgress)
        novelReader = nil
        mangaReader?.end()
        mangaReader?.model.finish(savingProgress: savingProgress)
        mangaReader = nil
    }

    func threadModel(for context: ThreadNovelLaunchContext, dependencies: ForumDependencies) -> ForumThreadReaderViewModel {
        if let model = threadModels[context.thread.tid] { return model }
        let model = ForumThreadReaderViewModel(context: context, dependencies: dependencies)
        model.persistsReadingActivity = !isPreview
        model.recordsReaderSessionHistory = true
        threadModels[context.thread.tid] = model
        return model
    }

    @discardableResult
    func openOriginalPost(
        url: URL,
        resumeRoute: ReaderResumeRoute,
        saveProgress: @escaping @MainActor () async -> ReaderResumeRoute
    ) async -> Bool {
        guard !isSwitching, !isClosed, acceptsResumeRoute(resumeRoute) else { return false }
        let previousID = contentID
        updateResumeRoute(resumeRoute, contentID: previousID)
        let dependencies = self.dependencies.forum
        let title: String
        let authorID: String?
        let forumID: String?
        switch resumeRoute {
        case let .novel(context):
            title = context.threadTitle
            authorID = context.authorID
            forumID = threadModels[context.threadID]?.readerSwitchThread.fid ?? context.forumID
        case let .manga(context):
            title = context.displayTitle
            authorID = nil
            forumID = context.forumID
        }
        await transition(title: L10n.string("reader.switching_to_thread")) {
            // An exit save must finish even when the user cancels the lookup.
            // It runs alongside resolution, before committing the new mode.
            let saveTask = Task { await saveProgress() }
            if let cached = self.cachedOriginalPost(url: url) {
                let savedRoute = await saveTask.value
                try Task.checkCancellation()
                self.updateResumeRoute(savedRoute, contentID: previousID)
                return cached
            }
            let resolver = await dependencies.makeThreadRouteResolver()
            let resolution = try await resolver.resolveWithPage(YamiboThreadRouteRequest(
                threadURL: url,
                title: title,
                authorID: authorID,
                threadFid: forumID,
                intent: .nativeThreadReader
            ))
            let savedRoute = await saveTask.value
            try Task.checkCancellation()
            self.updateResumeRoute(savedRoute, contentID: previousID)
            switch resolution.target {
            case let .thread(payload), let .novel(payload), let .manga(payload), let .mangaDirect(payload):
                guard !payload.thread.tid.isEmpty else { throw ReaderSessionError.unavailableThread }
                return ReaderSessionPreparedContent(content: .thread(ThreadNovelLaunchContext(
                    thread: payload.thread,
                    title: payload.title,
                    initialPage: payload.initialPage,
                    targetPostID: payload.targetPostID,
                    authorID: payload.authorID,
                    isDiscussionView: true
                )), threadPage: resolution.preloadedPage)
            case .webFallback:
                throw ReaderSessionError.unavailableThread
            }
        }
        return !isClosed && previousID != contentID
    }

    private func cachedOriginalPost(url: URL) -> ReaderSessionPreparedContent? {
        guard YamiboDomain.isForumURL(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "goto" })?.value == "findpost",
              let tid = items.first(where: { $0.name == "ptid" })?.value,
              let postID = items.first(where: { $0.name == "pid" })?.value,
              let model = threadModels[tid], !model.isAuthorOnly, !model.isReverseOrder,
              let page = model.page, page.posts.contains(where: { $0.postID == postID }) else { return nil }
        return ReaderSessionPreparedContent(content: .thread(ThreadNovelLaunchContext(
            thread: model.readerSwitchThread, title: model.navigationTitle,
            initialPage: model.currentPage, targetPostID: postID,
            authorID: model.readerSwitchAuthorID, isDiscussionView: true
        )), threadPage: page)
    }

    func openReader(
        _ mode: YamiboThreadReaderOverride,
        from model: ForumThreadReaderViewModel,
        onFullScreenHandoff: (@MainActor () -> Void)? = nil
    ) async {
        guard !isSwitching, !isClosed, mode != .plainThread,
              case let .thread(context) = content,
              context.thread.tid == model.context.thread.tid else { return }
        if presentation == .embeddedThread { self.onFullScreenHandoff = onFullScreenHandoff }
        let resolver = ReaderModeLaunchResolver(dependencies: dependencies.forum)
        let thread = model.readerSwitchThread
        let title = model.navigationTitle
        let authorID = model.readerSwitchAuthorID
        let savedNovel = novelContexts[thread.tid]
        let savedManga = mangaContexts[thread.tid]
        let preview = isPreview
        await transition(title: L10n.string(mode == .manga ? "reader.switching_to_manga" : "reader.switching_to_novel")) {
            switch mode {
            case .novel:
                if let savedNovel { return ReaderSessionPreparedContent(content: .novel(savedNovel)) }
                return ReaderSessionPreparedContent(content: .novel(try await resolver.novelContext(
                    thread: thread, title: title, authorID: authorID, isPreview: preview
                )))
            case .manga:
                let context: MangaLaunchContext
                if let savedManga {
                    context = savedManga
                } else {
                    context = try await resolver.mangaContext(thread: thread, title: title, isPreview: preview)
                }
                return ReaderSessionPreparedContent(content: .manga(context))
            case .plainThread:
                throw ReaderSessionError.unavailableThread
            }
        }
    }

    func openMangaReader(_ context: MangaLaunchContext) async {
        await transition(title: L10n.string("reader.switching_to_manga")) {
            ReaderSessionPreparedContent(content: .manga(context))
        }
    }

    private func acceptsResumeRoute(_ route: ReaderResumeRoute) -> Bool {
        switch (content, route) {
        case (.novel, .novel), (.manga, .manga): true
        default: false
        }
    }

    private func remember(_ route: ReaderResumeRoute) {
        switch route {
        case let .novel(context):
            novelContexts[context.threadID] = context
        case let .manga(context):
            mangaContexts[context.originalThreadID] = context
            mangaContexts[context.chapterTID] = context
        }
    }

    private func transition(title: String = L10n.string("reader.switching"), _ resolve: @escaping @MainActor () async throws -> ReaderSessionPreparedContent) async {
        guard !isSwitching, !isClosed else { return }
        // Dismissing a cover need not trigger the retained column's onAppear.
        // An explicit mode switch restores its ownership before resolving.
        if presentation == .embeddedThread { activate() }
        isSwitching = true
        switchingTitle = title
        switchFailure = nil
        let expectedID = contentID
        let validator = dependencies.mangaReaderOpenValidator
        let task = Task { [weak self] in
            do {
                let prepared = try await resolve()
                let next = prepared.content
                guard !Task.isCancelled, self?.isClosed == false, self?.contentID == expectedID else { return }
                let mangaProjection: MangaReaderProjection?
                if case let .manga(context) = next {
                    mangaProjection = try await validator.validate(context)
                } else {
                    mangaProjection = nil
                }
                guard let self, !Task.isCancelled, !self.isClosed, self.contentID == expectedID else { return }
                if case let .thread(context) = next {
                    self.threadModel(for: context, dependencies: self.dependencies.forum)
                        .prepareForOriginalPost(context: context, preloadedPage: prepared.threadPage)
                }
                // The original-post transition already flushes the captured
                // reading position before it can commit its new mode.
                self.present(next, mangaProjection: mangaProjection, savingPreviousPosition: next.resumeRoute != nil)
            } catch {
                guard let self, !Task.isCancelled, !self.isClosed, self.contentID == expectedID else { return }
                if !LoadDiagnosticError.isCancellation(error) {
                    self.switchFailure = LoadFailureDetails(error: error)
                }
                self.isSwitching = false
                self.switchTask = nil
            }
        }
        switchTask = task
        await task.value
    }

    func cancelSwitch() {
        switchTask?.cancel()
        switchTask = nil
        isSwitching = false
    }
}

private enum ReaderSessionError: LocalizedError {
    case unavailableThread

    var errorDescription: String? { L10n.string("forum.open_native_failed") }
}

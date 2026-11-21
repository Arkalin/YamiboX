import Observation
import SwiftUI
import YamiboXCore

struct MangaReaderViewModelDependencies {
    var settingsStore: SettingsStore
    var imagePipeline: any YamiboImageDataLoading
    var makeProjectionLoader: @Sendable () async -> any MangaReaderProjectionLoading
    var makeDirectoryRepository: @Sendable () async -> any MangaDirectoryRepository
    var makeDirectoryStore: @Sendable () -> any MangaDirectoryPersisting
    var makeDownloadStore: @Sendable () -> (any MangaDownloadStoring & DownloadQueueStoring)?
    var makeDirectorySearchCooldownState: @Sendable () -> MangaDirectorySearchCooldownState
    var makeChapterCommentsRepository: (@Sendable () async -> any ReaderChapterCommentsLoading)?
    var makeContentCoverStore: @Sendable () -> ContentCoverStore?
    var makeBrowsingHistoryWorkflow: @Sendable () -> BrowsingHistoryWorkflow
    var makeLikeDependencies: @Sendable () -> LikeDependencies?
    var makeThreadCoverPageRepository: @Sendable () async -> (any ThreadCoverPageResolving)?
    var directoryWorkflowConfiguration: MangaDirectoryWorkflowConfiguration
    var progressSync: ProgressSyncModule

    init(
        settingsStore: SettingsStore,
        imagePipeline: any YamiboImageDataLoading = YamiboImagePipeline(),
        makeProjectionLoader: @escaping @Sendable () async -> any MangaReaderProjectionLoading,
        makeDirectoryRepository: @escaping @Sendable () async -> any MangaDirectoryRepository,
        makeDirectoryStore: @escaping @Sendable () -> any MangaDirectoryPersisting,
        makeDownloadStore: @escaping @Sendable () -> (any MangaDownloadStoring & DownloadQueueStoring)? = { nil },
        makeDirectorySearchCooldownState: @escaping @Sendable () -> MangaDirectorySearchCooldownState = {
            MangaDirectorySearchCooldownState()
        },
        makeChapterCommentsRepository: (@Sendable () async -> any ReaderChapterCommentsLoading)? = nil,
        makeContentCoverStore: @escaping @Sendable () -> ContentCoverStore? = { nil },
        makeBrowsingHistoryWorkflow: @escaping @Sendable () -> BrowsingHistoryWorkflow,
        makeLikeDependencies: @escaping @Sendable () -> LikeDependencies? = { nil },
        makeThreadCoverPageRepository: @escaping @Sendable () async -> (any ThreadCoverPageResolving)? = { nil },
        directoryWorkflowConfiguration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration(),
        progressSync: ProgressSyncModule
    ) {
        self.settingsStore = settingsStore
        self.imagePipeline = imagePipeline
        self.makeProjectionLoader = makeProjectionLoader
        self.makeDirectoryRepository = makeDirectoryRepository
        self.makeDirectoryStore = makeDirectoryStore
        self.makeDownloadStore = makeDownloadStore
        self.makeDirectorySearchCooldownState = makeDirectorySearchCooldownState
        self.makeChapterCommentsRepository = makeChapterCommentsRepository
        self.makeContentCoverStore = makeContentCoverStore
        self.makeBrowsingHistoryWorkflow = makeBrowsingHistoryWorkflow
        self.makeLikeDependencies = makeLikeDependencies
        self.makeThreadCoverPageRepository = makeThreadCoverPageRepository
        self.directoryWorkflowConfiguration = directoryWorkflowConfiguration
        self.progressSync = progressSync
    }

    init(dependencies: MangaReaderDependencies) {
        self.init(
            settingsStore: dependencies.settingsStore,
            imagePipeline: dependencies.imagePipeline,
            makeProjectionLoader: { await dependencies.makeProjectionLoader() },
            makeDirectoryRepository: { await dependencies.makeDirectoryRepository() },
            makeDirectoryStore: { dependencies.mangaDirectoryStore },
            makeDownloadStore: { dependencies.downloadStore },
            makeDirectorySearchCooldownState: { dependencies.mangaDirectorySearchCooldownState },
            makeChapterCommentsRepository: { await dependencies.makeChapterCommentsRepository() },
            makeContentCoverStore: { dependencies.contentCoverStore },
            makeBrowsingHistoryWorkflow: { dependencies.browsingHistoryWorkflow },
            makeLikeDependencies: { dependencies.like },
            makeThreadCoverPageRepository: { await dependencies.makeForumThreadReaderRepository() },
            progressSync: ProgressSyncModule(
                adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: dependencies.readingProgressStore,
                    browsingHistoryWorkflow: dependencies.browsingHistoryWorkflow,
                    settingsStore: dependencies.settingsStore
                )
            )
        )
    }
}

@MainActor
@Observable
public final class MangaReaderViewModel {
    let annotationOperations = AnnotationOperationState()
    var currentDirectoryID: MangaDirectoryID? {
        guard case let .loaded(loaded) = presentation.state else { return nil }
        return loaded.directoryID
    }
    public private(set) var presentation: MangaReaderPresentation
    public private(set) var applePencilPageTurnSettings = ApplePencilPageTurnSettings()
    public private(set) var chapterCommentsState: ReaderChapterCommentsState = .idle
    public private(set) var isLoadingMoreChapterComments = false
    public private(set) var chapterCommentsLoadMoreError: String?
    private(set) var chapterCommentsLoadMoreErrorDetails: LoadFailureDetails?
    public private(set) var chapterCommentsRefreshError: String?
    private(set) var chapterCommentsRefreshErrorDetails: LoadFailureDetails?
    private(set) var chapterCommentsFailureEventID: UUID?
    var chapterJumpErrorMessage: String? {
        didSet {
            chapterJumpErrorDetails = nil
            chapterJumpFeedbackID = UUID()
        }
    }
    var chapterJumpErrorDetails: LoadFailureDetails?
    private var chapterJumpFeedbackID = UUID()
    var chapterJumpFeedback: TransientFeedback? {
        chapterJumpErrorMessage.map {
            TransientFeedback(message: $0, details: chapterJumpErrorDetails ?? LoadFailureDetails(message: $0), id: chapterJumpFeedbackID)
        }
    }
    var pageBoundary: ReaderPageBoundary?
    public private(set) var likedPageIDs: Set<String> = []
    public private(set) var annotationCapsule = ReaderAnnotationCapsulePresentation(bookmarkCount: 0, likeCount: 0)
    public private(set) var isCurrentPageBookmarked = false

    public let context: MangaLaunchContext
    @ObservationIgnored private(set) var imageLoader: MangaReaderPageImageLoader?

    let dependencies: MangaReaderViewModelDependencies
    @ObservationIgnored private let uiImagePipeline: YamiboUIImagePipeline
    private let onReaderResumeRouteChange: ReaderResumeRouteChangeHandler
    @ObservationIgnored private var chapterCommentsRepository: (any ReaderChapterCommentsLoading)?
    @ObservationIgnored private var workflow: MangaReaderWorkflow?
    @ObservationIgnored private var committedSettings = MangaReaderSettings()
    @ObservationIgnored private var viewportSettingsTarget = ReaderSettingsTarget.device
    @ObservationIgnored private var currentStableReadingPosition: MangaReadingPosition?
    @ObservationIgnored private var lastQueuedProgressSnapshot: MangaReaderProgressSnapshot?
    @ObservationIgnored private var progressRevision = UUID()
    @ObservationIgnored private var downloadOwnerName: String?
    @ObservationIgnored private lazy var lifecycle: MangaReaderLifecycleCoordinator = MangaReaderLifecycleCoordinator { [weak self] in
        guard let self else { return }
        navigation.invalidatePendingNavigation()
        directoryLane.cancelTasks()
        likeModule.cancelObservation()
        coverModule.cancelAutoThreadCoverResolution()
        chapterCommentsModule.cancelLoading()
    }
    @ObservationIgnored private lazy var chapterCommentsModule = ReaderChapterCommentsModule(
        adapter: ReaderChapterCommentsModule.Adapter(
            loadInitial: { [weak self] target in
                guard let self else {
                    throw ReaderChapterCommentsUnavailableError()
                }
                let repository = try await self.ensureChapterCommentsRepository()
                return try await repository.loadChapterComments(for: target)
            },
            loadMore: { [weak self] target, view in
                guard let self else {
                    throw ReaderChapterCommentsUnavailableError()
                }
                let repository = try await self.ensureChapterCommentsRepository()
                return try await repository.loadMoreChapterComments(for: target, view: view)
            },
            loadRatings: { [weak self] target, request in
                guard let self else { throw ReaderChapterCommentsUnavailableError() }
                let repository = try await self.ensureChapterCommentsRepository()
                return try await repository.loadRatingReasons(for: target, request: request)
            }
        ),
        onChange: { [weak self] snapshot in
            MainActor.assumeIsolated {
                self?.syncChapterComments(snapshot)
            }
        }
    )

    @ObservationIgnored private lazy var navigation = MangaReaderNavigationCoordinator(
        reading: MangaReaderNavigationCoordinator.Reading(
            stableReadingPosition: { [weak self] in self?.currentStableReadingPosition },
            restorePosition: { [weak self] targetPosition in
                await self?.performNavigationRestoreAttempt(to: targetPosition) ?? .aborted
            },
            scheduleAdjacentPrefetch: { [weak self] globalIndex in
                self?.scheduleAdjacentPrefetch(around: globalIndex)
            }
        )
    )

    @ObservationIgnored private lazy var likeModule = MangaReaderLikeModule(
        reading: MangaReaderLikeModule.Reading(
            isSmartModeEnabled: context.isSmartModeEnabled,
            forumID: context.forumID,
            currentDirectoryID: { [weak self] in self?.workflow?.currentDirectoryID() },
            makeLikeDependencies: dependencies.makeLikeDependencies,
            imageData: { [imagePipeline = dependencies.imagePipeline] in try await imagePipeline.data(for: $0) },
            imageSource: { [weak self] page in
                self?.imageSource(for: page) ?? page.mangaReaderImageSource(offlineScope: nil)
            },
            setLikedPageIDs: { [weak self] likedPageIDs in
                guard let self, lifecycle.acceptsResults else { return }
                self.likedPageIDs = likedPageIDs
                lifecycle.start(.annotationRefresh) { [weak self] _ in
                    await self?.refreshAnnotationState()
                }
            },
            onFailure: { [weak self] error in self?.annotationOperations.report(error) }
        )
    )

    @ObservationIgnored private lazy var coverModule = MangaReaderCoverModule(
        reading: MangaReaderCoverModule.Reading(
            isSmartModeEnabled: context.isSmartModeEnabled,
            chapterTID: context.chapterTID,
            displayTitle: context.displayTitle,
            currentDirectoryID: { [weak self] in self?.workflow?.currentDirectoryID() },
            makeContentCoverStore: dependencies.makeContentCoverStore,
            makeThreadCoverPageRepository: dependencies.makeThreadCoverPageRepository,
            imageSource: { [weak self] page in
                self?.imageSource(for: page) ?? page.mangaReaderImageSource(offlineScope: nil)
            },
            isReaderLoaded: { [weak self] in
                guard let self, case .loaded = self.presentation.state else { return false }
                return true
            }
        )
    )

    @ObservationIgnored private lazy var browsingHistoryRecorder = MangaReaderBrowsingHistoryRecorder(
        context: context,
        reading: MangaReaderBrowsingHistoryRecorder.Reading(
            makeBrowsingHistoryWorkflow: dependencies.makeBrowsingHistoryWorkflow,
            currentDirectory: { [weak self] in self?.workflow?.currentHistoryDirectory() }
        )
    )

    @ObservationIgnored private(set) lazy var directoryLane = MangaReaderDirectoryLane(
        dependencies: dependencies,
        reader: MangaReaderDirectoryLane.Reader(
            workflow: { [weak self] in self?.workflow },
            presentation: { [weak self] in
                self?.presentation ?? MangaReaderPresentation(
                    state: .loading(MangaReaderLoadingPresentation(title: ""))
                )
            },
            setPresentation: { [weak self] presentation in
                guard let self, lifecycle.acceptsResults else { return }
                self.presentation = presentation
            },
            progressSnapshot: { [weak self] presentation in self?.progressSnapshot(from: presentation) },
            publishPresentation: { [weak self] nextPresentation, previousProgressSnapshot in
                self?.publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            },
            downloadOwnerName: { [weak self] in self?.downloadOwnerName }
        )
    )

    public convenience init(
        context: MangaLaunchContext,
        dependencies: MangaReaderDependencies,
        initialProjection: MangaReaderProjection? = nil,
        imagePipeline: YamiboUIImagePipeline? = nil,
        onReaderResumeRouteChange: @escaping ReaderResumeRouteChangeHandler = { _ in }
    ) {
        self.init(
            context: context,
            viewModelDependencies: MangaReaderViewModelDependencies(dependencies: dependencies),
            initialProjection: initialProjection,
            imagePipeline: imagePipeline,
            onReaderResumeRouteChange: onReaderResumeRouteChange
        )
    }

    init(
        context: MangaLaunchContext,
        viewModelDependencies: MangaReaderViewModelDependencies,
        initialProjection: MangaReaderProjection? = nil,
        imagePipeline: YamiboUIImagePipeline? = nil,
        onReaderResumeRouteChange: @escaping ReaderResumeRouteChangeHandler = { _ in }
    ) {
        self.context = context
        self.initialProjection = initialProjection
        self.dependencies = viewModelDependencies
        self.uiImagePipeline = imagePipeline ?? YamiboUIImagePipeline(core: viewModelDependencies.imagePipeline)
        self.onReaderResumeRouteChange = onReaderResumeRouteChange
        self.imageLoader = nil
        self.presentation = MangaReaderPresentation(
            state: .loading(MangaReaderLoadingPresentation(title: Self.presentationTitle(for: context)))
        )
    }

    @ObservationIgnored private var initialProjection: MangaReaderProjection?

    func close() {
        progressRevision = UUID()
        lifecycle.close()
    }

    func finish(savingProgress: Bool) {
        if savingProgress { flushViewportSnapshot() }
        close()
    }

    func flushViewportSnapshot() {
        guard !context.isPreview, let snapshot = progressSnapshot(from: presentation) else { return }
        progressRevision = UUID()
        let date = Date.now
        Task { [progressSync = dependencies.progressSync] in
            try? await progressSync.flush(.manga(snapshot.progress), activityDate: date)
        }
    }

    public func prepare() async {
        await lifecycle.prepare { [weak self] request in
            await self?.prepareContent(request: request) ?? false
        }
    }

    private func prepareContent(request: MangaReaderLifecycleCoordinator.Request) async -> Bool {
        invalidateReaderContent()
        lastQueuedProgressSnapshot = nil

        let appSettings = await dependencies.settingsStore.load()
        guard lifecycle.accepts(request) else { return false }
        committedSettings = Self.normalizedSettings(appSettings.mangaSettings(for: viewportSettingsTarget))
        applePencilPageTurnSettings = appSettings.system.applePencilPageTurn
        presentation = presentationWithCommittedSettings(presentation)
        let imageLoader = MangaReaderPageImageLoader(
            imageSource: { [weak self] page in
                self?.imageSource(for: page) ?? page.mangaReaderImageSource(offlineScope: nil)
            },
            uiImagePipeline: uiImagePipeline
        )
        var directoryWorkflowConfiguration = dependencies.directoryWorkflowConfiguration
        directoryWorkflowConfiguration.searchForumID = context.forumID ?? "30"
        let workflow = MangaReaderWorkflow(
            context: context,
            projectionLoader: await dependencies.makeProjectionLoader(),
            directoryRepository: await dependencies.makeDirectoryRepository(),
            directoryStore: dependencies.makeDirectoryStore(),
            downloadStore: dependencies.makeDownloadStore(),
            settings: committedSettings,
            directoryWorkflowConfiguration: directoryWorkflowConfiguration,
            directorySearchCooldownState: dependencies.makeDirectorySearchCooldownState()
        )
        guard lifecycle.accepts(request) else { return false }
        self.workflow = workflow
        self.imageLoader = imageLoader
        presentation = workflow.presentation
        let initialProjection = self.initialProjection
        self.initialProjection = nil
        let preparedPresentation = await workflow.prepare(initialProjection: initialProjection)
        guard lifecycle.accepts(request) else { return false }
        presentation = preparedPresentation
        currentStableReadingPosition = stableReadingPosition(from: presentation)
        updateDownloadOwnerName(from: presentation)
        directoryLane.refreshDirectoryPanelTiming(errorMessage: nil)
        if workflow.shouldAutoUpdateDirectoryAfterPrepare {
            directoryLane.startAutomaticDirectoryUpdate()
        }
        await likeModule.refreshLikedPageIDs()
        guard lifecycle.accepts(request) else { return false }
        likeModule.observeLikeChangesIfNeeded()
        await refreshAnnotationState()
        guard lifecycle.accepts(request) else { return false }
        observeBookmarkChangesIfNeeded()
        observeDirectoryChanges()
        coverModule.startAutoThreadCoverResolutionIfNeeded()
        browsingHistoryRecorder.syncRecordIfNeeded(presentation: presentation)
        if case .loaded = presentation.state { return true }
        return false
    }

    public func retryInitialLoad() async {
        guard await lifecycle.resetForRetry() else { return }
        workflow = nil
        imageLoader = nil
        downloadOwnerName = nil
        navigation.resetHistory()
        currentStableReadingPosition = nil
        lastQueuedProgressSnapshot = nil
        browsingHistoryRecorder.reset()
        directoryLane.resetCooldownState()
        presentation = presentationWithCommittedSettings(
            MangaReaderPresentation(
                state: .loading(MangaReaderLoadingPresentation(title: Self.presentationTitle(for: context)))
            )
        )

        await prepare()
    }

    func updateCurrentPage(visiblePage: MangaReaderPageProjection, placement: MangaNovelReaderViewportPlacement?) {
        guard case let .loaded(loaded) = presentation.state,
              loaded.viewportPlacement == placement,
              let index = loaded.pages.firstIndex(where: { $0.id == visiblePage.id }),
              loaded.currentPageIndex != index else { return }
        updateCurrentPage(globalIndex: index)
    }

    public func updateCurrentPage(globalIndex: Int) {
        guard let workflow else { return }
        let previousGlobalIndex = currentPageIndex(in: presentation)
        lifecycle.invalidateContent()
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        let nextPresentation = workflow.moveToLoadedPage(at: globalIndex)
        publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
        let direction: ReaderNavigationLinearReadingDirection =
            (previousGlobalIndex.map { globalIndex < $0 } ?? false) ? .backward : .forward
        navigation.recordLinearReading(direction: direction)
        scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? globalIndex)
    }

    public func jumpToPage(localIndex: Int) async {
        guard let workflow,
              case let .loaded(loaded) = presentation.state,
              let currentPage = loaded.currentPage else {
            return
        }
        let navigationGeneration = navigation.beginNavigationRequest()
        let sourcePosition = currentStableReadingPosition
        let itemCount = max(currentPage.chapterPageCount, 1)
        let targetLocalIndex = min(max(localIndex, 0), itemCount - 1)
        guard let targetPage = loaded.pages.first(where: { page in
            page.tid == currentPage.tid && page.localIndex == targetLocalIndex
        }) else {
            return
        }
        let targetPosition = MangaReadingPosition(tid: targetPage.tid, localIndex: targetPage.localIndex)

        lifecycle.invalidateContent()
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        let nextPresentation = workflow.jumpToLoadedPage(at: targetPage.globalIndex)
        publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
        if navigation.isCurrentNavigationRequest(navigationGeneration) {
            navigation.recordSuccessfulNonlinearNavigation(from: sourcePosition, to: targetPosition)
        }
        scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? targetPage.globalIndex)
    }

    public func jumpRelativePage(_ delta: Int, usesTwoPageSpread: Bool) async {
        guard let workflow,
              let target = relativePageTurnTarget(for: delta, usesTwoPageSpread: usesTwoPageSpread) else {
            return
        }

        switch target {
        case let .chapterBoundary(sourcePosition):
            await jumpToAdjacentChapterBoundary(
                delta: delta,
                sourcePosition: sourcePosition,
                workflow: workflow
            )
        case let .loadedPage(targetGlobalIndex):
            pageBoundary = nil
            lifecycle.invalidateContent()
            let previousProgressSnapshot = progressSnapshot(from: presentation)
            let nextPresentation = workflow.jumpToLoadedPage(at: targetGlobalIndex, animated: true)
            publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            navigation.recordLinearReading(direction: delta >= 0 ? .forward : .backward)
            scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? targetGlobalIndex)
        }
    }

    public func canJumpRelativePage(_ delta: Int, usesTwoPageSpread: Bool) -> Bool {
        guard let workflow,
              let target = relativePageTurnTarget(for: delta, usesTwoPageSpread: usesTwoPageSpread) else {
            return false
        }
        switch target {
        case .loadedPage:
            return true
        case let .chapterBoundary(sourcePosition):
            return workflow.canJumpToAdjacentChapter(from: sourcePosition, delta: delta)
        }
    }

    private enum RelativePageTurnTarget {
        case loadedPage(Int)
        case chapterBoundary(MangaReadingPosition?)
    }

    private func relativePageTurnTarget(for delta: Int, usesTwoPageSpread: Bool) -> RelativePageTurnTarget? {
        guard delta != 0,
              presentation.settings.readingMode == .paged,
              case let .loaded(loaded) = presentation.state,
              !loaded.pages.isEmpty else {
            return nil
        }

        let plan = MangaPagedReadingPlan(
            pages: loaded.pages,
            currentPageIndex: loaded.currentPageIndex,
            pageTurnDirection: presentation.settings.pageTurnDirection,
            usesTwoPageSpread: usesTwoPageSpread
        )
        let targetGlobalIndex: Int?
        if usesTwoPageSpread {
            targetGlobalIndex = plan.currentSpreadIndex.flatMap { currentSpreadIndex in
                plan.globalIndex(forSpreadAt: currentSpreadIndex + delta)
            }
        } else {
            targetGlobalIndex = plan.currentPageIndex.flatMap { currentPageIndex in
                plan.globalIndex(forPageAt: currentPageIndex + delta)
            }
        }
        if let targetGlobalIndex {
            return .loadedPage(targetGlobalIndex)
        }
        return .chapterBoundary(stableReadingPosition(from: loaded))
    }

    public func jumpToAdjacentChapterFromVerticalBoundary(_ delta: Int) async {
        guard delta != 0,
              let workflow,
              presentation.settings.readingMode == .vertical,
              case let .loaded(loaded) = presentation.state,
              !loaded.pages.isEmpty else {
            return
        }
        await jumpToAdjacentChapterBoundary(
            delta: delta,
            sourcePosition: stableReadingPosition(from: loaded),
            workflow: workflow
        )
    }

    func reportVerticalPageBoundary(_ delta: Int) {
        guard abs(delta) == 1, !lifecycle.isRunning(.chapterJump), !lifecycle.hasAdjacentNavigation, let workflow,
              presentation.settings.readingMode == .vertical,
              case let .loaded(loaded) = presentation.state,
              !loaded.pages.isEmpty,
              let position = stableReadingPosition(from: loaded),
              !workflow.canJumpToAdjacentChapter(from: position, delta: delta) else { return }
        pageBoundary = ReaderPageBoundary(delta: delta)
    }

    public var currentChapterCommentTarget: ReaderChapterCommentTarget? {
        guard case let .loaded(loaded) = presentation.state,
              let currentPage = loaded.currentPage else {
            return nil
        }
        return ReaderChapterCommentTarget(
            threadID: currentPage.tid,
            view: currentPage.sourceIdentity.view,
            ownerPostID: currentPage.ownerPostID,
            title: currentPage.chapterTitle
        )
    }

    public var currentForumTargetURL: URL {
        guard let target = currentChapterCommentTarget else {
            return YamiboRoute.threadByID(
                tid: context.originalThreadID,
                page: 1,
                authorID: nil,
                reverse: false
            ).url
        }
        return YamiboRoute.findPostURL(threadID: target.threadID, postID: target.ownerPostID)
            ?? YamiboRoute.threadByID(
                tid: target.threadID,
                page: target.view,
                authorID: nil,
                reverse: false
            ).url
    }

    func imageSource(for page: MangaReaderPageProjection) -> YamiboImageSource {
        let scope = downloadOwnerName.flatMap { ownerName in
            YamiboImageOfflineScope(tid: page.tid, ownerName: ownerName)
        }
        return page.mangaReaderImageSource(offlineScope: scope)
    }

    var canSetMangaCover: Bool {
        coverModule.canSetMangaCover
    }

    func hasManualMangaCover() async -> Bool {
        await coverModule.hasManualMangaCover()
    }

    func setMangaCover(page: MangaReaderPageProjection) async -> Bool {
        await coverModule.setMangaCover(page: page)
    }

    var coverActionFailureDetails: LoadFailureDetails? { coverModule.failureDetails }
    var coverActionWasCancelled: Bool { coverModule.actionWasCancelled }
    var likeActionFailureDetails: LoadFailureDetails? { likeModule.failureDetails }
    var likeActionWasCancelled: Bool { likeModule.actionWasCancelled }

    func restoreAutomaticMangaCover() async -> Bool {
        await coverModule.restoreAutomaticMangaCover()
    }

    var canShowLikes: Bool {
        likeModule.canShowLikes
    }

    var likeSheetContext: (workKey: ReadingWorkKey, like: LikeDependencies)? {
        likeModule.likeSheetContext
    }

    func likePage(_ page: MangaReaderPageProjection) async -> LikeCaptureOutcome? {
        await likeModule.likePage(page)
    }

    func isPageLiked(_ page: MangaReaderPageProjection) async throws -> LikeItem? {
        try await likeModule.isPageLiked(page)
    }

    var currentPageProjection: MangaReaderPageProjection? {
        guard case let .loaded(loaded) = presentation.state else { return nil }
        if let currentPage = loaded.currentPage { return currentPage }
        if let index = loaded.currentPageIndex, loaded.pages.indices.contains(index) {
            return loaded.pages[index]
        }
        return loaded.pages.first
    }

    private func bookmarkAnchor(for page: MangaReaderPageProjection) -> BookmarkAnchorPayload {
        .manga(
            MangaBookmarkAnchor(
                chapterTID: page.tid,
                pageLocalIndex: page.localIndex,
                globalPageIndex: page.globalIndex,
                chapterTitle: page.chapterTitle,
                forumID: context.forumID
            )
        )
    }

    @discardableResult
    func toggleBookmarkForCurrentPage() async -> Bool? {
        let revision = lifecycle.contentRevision
        guard let annotation = likeModule.likeSheetContext,
              let page = currentPageProjection else {
            return nil
        }
        guard let outcome = await annotationOperations.perform({
            try await annotation.like.annotations.toggleBookmark(
                work: annotation.workKey, anchor: bookmarkAnchor(for: page)
            )
        }), lifecycle.accepts(revision) else { return nil }
        isCurrentPageBookmarked = outcome.isBookmarked
        await refreshAnnotationState()
        return outcome.isBookmarked
    }

    func refreshCurrentPageBookmarkState() async {
        let revision = lifecycle.contentRevision
        guard lifecycle.accepts(revision) else { return }
        guard let annotation = likeModule.likeSheetContext,
              let page = currentPageProjection else {
            isCurrentPageBookmarked = false
            return
        }
        guard let isBookmarked = await annotationOperations.perform({
            try await annotation.like.bookmarkStore
                .bookmark(marking: bookmarkAnchor(for: page), in: annotation.workKey) != nil
        }), lifecycle.accepts(revision), currentPageProjection?.id == page.id else { return }
        isCurrentPageBookmarked = isBookmarked
    }

    func refreshAnnotationState() async {
        let revision = lifecycle.contentRevision
        guard lifecycle.accepts(revision) else { return }
        guard let annotation = likeModule.likeSheetContext else {
            annotationCapsule = ReaderAnnotationCapsulePresentation(bookmarkCount: 0, likeCount: 0)
            isCurrentPageBookmarked = false
            return
        }
        guard let (bookmarkCount, likeCount) = await annotationOperations.perform({
            let bookmarks = try await annotation.like.bookmarkStore.count(for: annotation.workKey)
            let likes = try await annotation.like.likeStore.likes(for: annotation.workKey).count
            return (bookmarks, likes)
        }), lifecycle.accepts(revision) else { return }
        annotationCapsule = ReaderAnnotationCapsulePresentation(
            bookmarkCount: bookmarkCount,
            likeCount: likeCount
        )
        await refreshCurrentPageBookmarkState()
    }

    private func observeBookmarkChangesIfNeeded() {
        guard !lifecycle.isRunning(.bookmarkObservation),
              let annotation = likeModule.likeSheetContext else {
            return
        }
        let bookmarkStore = annotation.like.bookmarkStore
        lifecycle.start(.bookmarkObservation) { [weak self] request in
            for await _ in bookmarkStore.changes() {
                guard self?.lifecycle.accepts(request) == true else { return }
                await self?.refreshAnnotationState()
            }
        }
    }

    var annotationSheetContext: (workKey: ReadingWorkKey, like: LikeDependencies)? {
        likeModule.likeSheetContext
    }

    func unlikePage(_ item: LikeItem) async -> Bool {
        await likeModule.unlikePage(item)
    }

    func jumpToLikedMangaPage(tid: String, localIndex: Int) async -> Bool {
        guard let workflow else { return false }
        let navigationGeneration = navigation.beginNavigationRequest()
        let sourcePosition = currentStableReadingPosition
        let targetPosition = MangaReadingPosition(tid: tid, localIndex: localIndex)
        lifecycle.invalidateContent()
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        do {
            let nextPresentation = try await workflow.jumpToPosition(targetPosition)
            publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            if navigation.isCurrentNavigationRequest(navigationGeneration) {
                navigation.recordSuccessfulNonlinearNavigation(from: sourcePosition, to: targetPosition)
            }
            scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? 0)
            return true
        } catch {
            return false
        }
    }

    public func loadChapterComments(for target: ReaderChapterCommentTarget?) async {
        await chapterCommentsModule.loadAndContinue(target)
    }

    public func refreshChapterComments(for target: ReaderChapterCommentTarget?) async {
        guard let target else { return }
        await chapterCommentsModule.refreshAndContinue(target)
    }

    public func loadNextChapterCommentsPage() async {
        await chapterCommentsModule.continueLoading()
    }

    func cancelChapterCommentsLoading() { chapterCommentsModule.cancelLoading() }

    func clearChapterCommentsFailure() {
        chapterCommentsModule.clearTransientFailure()
    }

    func clearDirectoryFailure() {
        directoryLane.refreshDirectoryPanelTiming(errorMessage: nil)
    }

    func applyViewportSettings(_ settings: MangaReaderSettings, target: ReaderSettingsTarget) {
        viewportSettingsTarget = target
        let normalizedSettings = Self.normalizedSettings(settings)
        guard normalizedSettings != committedSettings else { return }

        committedSettings = normalizedSettings
        if let workflow {
            presentation = workflow.applySettings(normalizedSettings)
            directoryLane.refreshDirectoryPanelTiming(errorMessage: directoryLane.currentDirectoryPanelErrorMessage)
        } else {
            presentation = presentationWithCommittedSettings(presentation)
        }

    }

    func saveViewportSettings(_ settings: MangaReaderSettings, for target: ReaderSettingsTarget) async throws {
        let normalized = Self.normalizedSettings(settings)
        try await dependencies.settingsStore.update { $0.updateMangaSettings(normalized, for: target) }
    }

    func saveDirectorySortOrder(_ order: MangaDirectorySortOrder, for target: ReaderSettingsTarget) {
        Task { [settingsStore = dependencies.settingsStore] in
            do {
                try await settingsStore.update {
                    var settings = $0.mangaSettings(for: target)
                    settings.directorySortOrder = order
                    $0.updateMangaSettings(settings, for: target)
                }
            } catch {
                YamiboLog.persistence.error("Failed to save manga directory sort order: \(error.localizedDescription)")
            }
        }
    }

    public func jumpToChapter(_ chapter: MangaChapter) async {
        chapterJumpErrorMessage = nil
        invalidateReaderContent()
        let navigationGeneration = navigation.beginNavigationRequest()
        let sourcePosition = currentStableReadingPosition
        let task = lifecycle.start(.chapterJump) { [weak self] request in
            await self?.performJumpToChapter(
                chapter,
                sourcePosition: sourcePosition,
                navigationGeneration: navigationGeneration,
                request: request
            )
        }
        await task?.value
    }

    public var canNavigateBack: Bool {
        navigation.canNavigateBack
    }

    public var canNavigateForward: Bool {
        navigation.canNavigateForward
    }

    public func navigateBack() async {
        await navigation.navigateBack()
    }

    public func navigateForward() async {
        await navigation.navigateForward()
    }

    private func performJumpToChapter(
        _ chapter: MangaChapter,
        sourcePosition: MangaReadingPosition?,
        navigationGeneration: Int,
        request: MangaReaderLifecycleCoordinator.Request
    ) async {
        guard let workflow else { return }
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        do {
            let nextPresentation = try await workflow.jumpToChapter(chapter)
            guard lifecycle.accepts(request) else { return }
            publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            if navigation.isCurrentNavigationRequest(navigationGeneration) {
                navigation.recordSuccessfulNonlinearNavigation(
                    from: sourcePosition,
                    to: MangaReadingPosition(tid: chapter.tid, localIndex: 0)
                )
            }
            directoryLane.refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            return
        } catch {
            guard lifecycle.accepts(request) else { return }
            YamiboLog.reader.error("Jumping to manga chapter failed: \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                chapterJumpErrorMessage = error.localizedDescription
                chapterJumpErrorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    @discardableResult
    public func saveProgress() async -> MangaLaunchContext {
        guard let snapshot = progressSnapshot(from: presentation) else {
            return context
        }
        lastQueuedProgressSnapshot = snapshot
        guard !context.isPreview else {
            return snapshot.resumeContext
        }

        progressRevision = UUID()
        let date = Date.now
        await onReaderResumeRouteChange(.manga(snapshot.resumeContext))
        do {
            try await dependencies.progressSync.flush(.manga(snapshot.progress), activityDate: date)
        } catch {
            YamiboLog.sync.error("Failed to flush final manga reading progress on close: \(error.localizedDescription)")
        }
        return snapshot.resumeContext
    }

    var currentResumeContext: MangaLaunchContext {
        progressSnapshot(from: presentation)?.resumeContext ?? context
    }

    var hasCurrentPage: Bool {
        if case let .loaded(loaded) = presentation.state { return loaded.currentPage != nil }
        return false
    }

    var viewportContentID: String {
        guard case let .loaded(loaded) = presentation.state else { return "" }
        return "\(loaded.readingPosition?.tid ?? "")#\(loaded.viewportPlacement?.revision ?? 0)#\(presentation.settings.readingMode)"
    }

    private func scheduleAdjacentPrefetch(around globalIndex: Int) {
        guard workflow != nil else { return }
        let revision = lifecycle.contentRevision
        lifecycle.start(.adjacentPrefetch) { [weak self] request in
            await self?.performAdjacentPrefetch(
                around: globalIndex,
                revision: revision,
                request: request
            )
        }
    }

    private func performAdjacentPrefetch(
        around globalIndex: Int,
        revision: MangaReaderLifecycleCoordinator.ContentRevision,
        request: MangaReaderLifecycleCoordinator.Request
    ) async {
        guard let workflow else { return }
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        guard let nextPresentation = await workflow.prefetchAdjacentChaptersIfNeeded(around: globalIndex) else {
            return
        }
        guard lifecycle.accepts(request), lifecycle.accepts(revision) else { return }
        publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
    }

    private func jumpToAdjacentChapterBoundary(
        delta: Int,
        sourcePosition: MangaReadingPosition?,
        workflow: MangaReaderWorkflow
    ) async {
        guard abs(delta) == 1, sourcePosition != nil else { return }
        guard workflow.canJumpToAdjacentChapter(from: sourcePosition, delta: delta) else {
            guard !lifecycle.isRunning(.chapterJump), !lifecycle.hasAdjacentNavigation else { return }
            pageBoundary = ReaderPageBoundary(delta: delta)
            return
        }

        pageBoundary = nil
        let navigationID = lifecycle.beginAdjacentNavigation()
        defer { lifecycle.finishAdjacentNavigation(navigationID) }
        let revision = lifecycle.contentRevision
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        do {
            let nextPresentation = try await workflow.jumpToAdjacentChapter(
                from: sourcePosition,
                delta: delta,
                animated: true
            )
            guard lifecycle.accepts(revision) else { return }
            publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            navigation.recordLinearReading(direction: delta >= 0 ? .forward : .backward)
            scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? 0)
        } catch is CancellationError {
            return
        } catch {
            YamiboLog.reader.warning("Jumping to adjacent manga chapter boundary failed: \(error.localizedDescription)")
            return
        }
    }

    func invalidateReaderContent() {
        lifecycle.invalidateContent()
    }

    private func observeDirectoryChanges() {
        guard !lifecycle.isRunning(.directoryObservation) else { return }
        let changes = dependencies.makeDirectoryStore().changes()
        lifecycle.start(.directoryObservation) { [weak self] request in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                guard let self, lifecycle.accepts(request), let workflow else { return }
                let previous = progressSnapshot(from: presentation)
                do {
                    if let updated = try await workflow.refreshPersistedDirectory(), lifecycle.accepts(request) {
                        publishPresentation(updated, previousProgressSnapshot: previous)
                        await likeModule.refreshLikedPageIDs()
                    }
                } catch {
                    YamiboLog.reader.warning("Could not refresh changed manga directory: \(error)")
                }
            }
        }
    }

    func publishPresentation(
        _ nextPresentation: MangaReaderPresentation,
        previousProgressSnapshot: MangaReaderProgressSnapshot?
    ) {
        guard lifecycle.acceptsResults else { return }
        if nextPresentation != presentation {
            presentation = nextPresentation
        }
        updateDownloadOwnerName(from: nextPresentation)
        currentStableReadingPosition = stableReadingPosition(from: nextPresentation)
        lifecycle.start(.bookmarkRefresh) { [weak self] _ in
            await self?.refreshCurrentPageBookmarkState()
        }
        browsingHistoryRecorder.syncRecordIfNeeded(presentation: presentation)
        let nextProgressSnapshot = progressSnapshot(from: nextPresentation)
        guard nextProgressSnapshot != previousProgressSnapshot
            || nextProgressSnapshot != lastQueuedProgressSnapshot else {
            return
        }
        scheduleProgressSync(snapshot: nextProgressSnapshot)
    }

    private func scheduleProgressSync(snapshot: MangaReaderProgressSnapshot?) {
        guard let snapshot else { return }
        lastQueuedProgressSnapshot = snapshot
        guard !context.isPreview else { return }
        let revision = UUID()
        progressRevision = revision
        let date = Date.now
        Task { [weak self] in
            guard let self, progressRevision == revision else { return }
            await onReaderResumeRouteChange(.manga(snapshot.resumeContext))
            await dependencies.progressSync.queue(.manga(snapshot.progress), activityDate: date)
        }
    }

    private func updateDownloadOwnerName(from presentation: MangaReaderPresentation) {
        guard case let .loaded(loaded) = presentation.state else {
            downloadOwnerName = nil
            return
        }
        downloadOwnerName = loaded.directoryID?.rawValue
    }

    private func currentPageIndex(in presentation: MangaReaderPresentation) -> Int? {
        guard case let .loaded(loaded) = presentation.state else { return nil }
        return loaded.currentPageIndex
    }

    private func stableReadingPosition(from presentation: MangaReaderPresentation) -> MangaReadingPosition? {
        guard case let .loaded(loaded) = presentation.state else { return nil }
        return stableReadingPosition(from: loaded)
    }

    private func stableReadingPosition(from loaded: MangaReaderLoadedPresentation) -> MangaReadingPosition? {
        if let readingPosition = loaded.readingPosition {
            return readingPosition
        }
        guard let currentPage = loaded.currentPage else { return nil }
        return MangaReadingPosition(tid: currentPage.tid, localIndex: currentPage.localIndex)
    }

    private func performNavigationRestoreAttempt(
        to targetPosition: MangaReadingPosition
    ) async -> MangaReaderNavigationCoordinator.RestoreAttemptOutcome {
        guard let workflow else { return .aborted }
        lifecycle.invalidateContent()
        let revision = lifecycle.contentRevision
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        do {
            let nextPresentation = try await workflow.jumpToPosition(targetPosition)
            guard lifecycle.accepts(revision) else { return .aborted }
            publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            return .restored(prefetchIndex: currentPageIndex(in: nextPresentation) ?? 0)
        } catch is CancellationError {
            return .aborted
        } catch {
            guard lifecycle.accepts(revision) else { return .aborted }
            YamiboLog.reader.warning("Restoring manga navigation history target failed, discarding and trying next: \(error.localizedDescription)")
            return .failed
        }
    }

    func progressSnapshot(from presentation: MangaReaderPresentation) -> MangaReaderProgressSnapshot? {
        guard case let .loaded(loaded) = presentation.state,
              let currentPage = loaded.currentPage else {
            return nil
        }

        let directoryName = Self.normalizedDirectoryName(loaded.directoryTitle) ?? Self.normalizedDirectoryName(context.directoryName)
        let progress = MangaProgressReadingPosition(
            threadID: context.originalThreadID,
            chapterThreadID: currentPage.tid,
            chapterView: currentPage.sourceIdentity.view,
            chapterTitle: currentPage.chapterTitle,
            pageIndex: currentPage.localIndex,
            pageCount: currentPage.chapterPageCount,
            mangaID: workflow?.currentDirectoryFavoriteIdentity(),
            directoryName: directoryName,
            isSmartModeEnabled: context.isSmartModeEnabled
        )
        let resumeContext = MangaLaunchContext(
            originalThreadID: context.originalThreadID,
            chapterTID: currentPage.tid,
            displayTitle: context.displayTitle,
            source: .resume,
            chapterView: currentPage.sourceIdentity.view,
            initialPage: currentPage.localIndex,
            directoryName: directoryName,
            directoryID: loaded.directoryID,
            downloadFavoriteID: context.downloadFavoriteID,
            isPreview: context.isPreview,
            isSmartModeEnabled: context.isSmartModeEnabled,
            forumID: context.forumID
        )
        return MangaReaderProgressSnapshot(
            progress: progress,
            resumeContext: resumeContext
        )
    }

    private func presentationWithCommittedSettings(
        _ presentation: MangaReaderPresentation
    ) -> MangaReaderPresentation {
        var nextPresentation = presentation
        nextPresentation.settings = committedSettings
        return nextPresentation
    }

    static func normalizedDirectoryName(_ directoryName: String?) -> String? {
        directoryName?.nilIfBlank
    }

    private func ensureChapterCommentsRepository() async throws -> any ReaderChapterCommentsLoading {
        if chapterCommentsRepository == nil {
            guard let makeChapterCommentsRepository = dependencies.makeChapterCommentsRepository else {
                throw ReaderChapterCommentsUnavailableError()
            }
            chapterCommentsRepository = await makeChapterCommentsRepository()
        }
        guard let chapterCommentsRepository else {
            preconditionFailure("Reader chapter comments repository should be initialized")
        }
        return chapterCommentsRepository
    }

    private func syncChapterComments(_ snapshot: ReaderChapterCommentsSnapshot) {
        chapterCommentsState = snapshot.state
        isLoadingMoreChapterComments = snapshot.isLoadingMore
        chapterCommentsLoadMoreError = snapshot.loadMoreError
        chapterCommentsLoadMoreErrorDetails = snapshot.loadMoreErrorDetails
        chapterCommentsRefreshError = snapshot.refreshError
        chapterCommentsRefreshErrorDetails = snapshot.refreshErrorDetails
        chapterCommentsFailureEventID = snapshot.failureEventID
    }

    private static func normalizedSettings(_ settings: MangaReaderSettings) -> MangaReaderSettings {
        var normalized = settings
        normalized.brightness = normalizedBrightness(settings.brightness)
        return normalized
    }

    private static func normalizedBrightness(_ brightness: Double) -> Double {
        guard brightness.isFinite else { return 1.0 }
        return min(1.5, max(0.25, brightness))
    }

    private static func presentationTitle(for context: MangaLaunchContext) -> String {
        let title = context.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? L10n.string("manga.reader.title") : title
    }
}

struct MangaReaderProgressSnapshot: Hashable, Sendable {
    var progress: MangaProgressReadingPosition
    var resumeContext: MangaLaunchContext
}

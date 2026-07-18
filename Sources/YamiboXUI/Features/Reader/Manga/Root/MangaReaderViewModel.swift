import Observation
import SwiftUI
import YamiboXCore

struct MangaReaderViewModelDependencies {
    var settingsStore: SettingsStore
    var makeProjectionLoader: @Sendable () async -> any MangaReaderProjectionLoading
    var makeDirectoryRepository: @Sendable () async -> any MangaDirectoryRepository
    var makeDirectoryStore: @Sendable () -> any MangaDirectoryPersisting
    var makeOfflineCacheStore: @Sendable () -> (any MangaOfflineCacheStoring & OfflineCacheQueueStoring)?
    var makeDirectorySearchCooldownState: @Sendable () -> MangaDirectorySearchCooldownState
    var makeChapterCommentsRepository: (@Sendable () async -> ReaderChapterCommentsRepository)?
    var makeContentCoverStore: @Sendable () -> ContentCoverStore?
    var makeBrowsingHistoryStore: @Sendable () -> BrowsingHistoryStore?
    var makeLikeDependencies: @Sendable () -> LikeDependencies?
    /// Smart Comic Mode off (design decision #16): drives the reader's
    /// auto-resolved `.thread(tid:)` cover for the chapter being read, via
    /// `ThreadCoverResolver`. `nil` by default so callers that don't care
    /// (tests, previews) don't need to supply one — the auto-resolution is
    /// simply skipped when unavailable.
    var makeThreadCoverPageRepository: @Sendable () async -> (any ThreadCoverPageResolving)?
    var directoryWorkflowConfiguration: MangaDirectoryWorkflowConfiguration
    var progressSync: ProgressSyncModule
    /// Migrates the favorite item's target and reading-progress records to a
    /// renamed manga title. No-op by default so callers that don't care
    /// (tests, previews) don't need to supply one.
    var migrateMangaTitleReferences: @Sendable (_ oldCleanBookName: String, _ newCleanBookName: String) async -> Void

    init(
        settingsStore: SettingsStore,
        makeProjectionLoader: @escaping @Sendable () async -> any MangaReaderProjectionLoading,
        makeDirectoryRepository: @escaping @Sendable () async -> any MangaDirectoryRepository,
        makeDirectoryStore: @escaping @Sendable () -> any MangaDirectoryPersisting,
        makeOfflineCacheStore: @escaping @Sendable () -> (any MangaOfflineCacheStoring & OfflineCacheQueueStoring)? = { nil },
        makeDirectorySearchCooldownState: @escaping @Sendable () -> MangaDirectorySearchCooldownState = {
            MangaDirectorySearchCooldownState()
        },
        makeChapterCommentsRepository: (@Sendable () async -> ReaderChapterCommentsRepository)? = nil,
        makeContentCoverStore: @escaping @Sendable () -> ContentCoverStore? = { nil },
        makeBrowsingHistoryStore: @escaping @Sendable () -> BrowsingHistoryStore? = { nil },
        makeLikeDependencies: @escaping @Sendable () -> LikeDependencies? = { nil },
        makeThreadCoverPageRepository: @escaping @Sendable () async -> (any ThreadCoverPageResolving)? = { nil },
        directoryWorkflowConfiguration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration(),
        progressSync: ProgressSyncModule,
        migrateMangaTitleReferences: @escaping @Sendable (_ oldCleanBookName: String, _ newCleanBookName: String) async -> Void = { _, _ in }
    ) {
        self.settingsStore = settingsStore
        self.makeProjectionLoader = makeProjectionLoader
        self.makeDirectoryRepository = makeDirectoryRepository
        self.makeDirectoryStore = makeDirectoryStore
        self.makeOfflineCacheStore = makeOfflineCacheStore
        self.makeDirectorySearchCooldownState = makeDirectorySearchCooldownState
        self.makeChapterCommentsRepository = makeChapterCommentsRepository
        self.makeContentCoverStore = makeContentCoverStore
        self.makeBrowsingHistoryStore = makeBrowsingHistoryStore
        self.makeLikeDependencies = makeLikeDependencies
        self.makeThreadCoverPageRepository = makeThreadCoverPageRepository
        self.directoryWorkflowConfiguration = directoryWorkflowConfiguration
        self.progressSync = progressSync
        self.migrateMangaTitleReferences = migrateMangaTitleReferences
    }

    init(dependencies: MangaReaderDependencies) {
        self.init(
            settingsStore: dependencies.settingsStore,
            makeProjectionLoader: { await dependencies.makeProjectionLoader() },
            makeDirectoryRepository: { await dependencies.makeDirectoryRepository() },
            makeDirectoryStore: { dependencies.mangaDirectoryStore },
            makeOfflineCacheStore: { dependencies.offlineCacheStore },
            makeDirectorySearchCooldownState: { dependencies.mangaDirectorySearchCooldownState },
            makeChapterCommentsRepository: { await dependencies.makeChapterCommentsRepository() },
            makeContentCoverStore: { dependencies.contentCoverStore },
            makeBrowsingHistoryStore: { dependencies.browsingHistoryStore },
            makeLikeDependencies: { dependencies.like },
            makeThreadCoverPageRepository: { await dependencies.makeForumThreadReaderRepository() },
            progressSync: ProgressSyncModule(
                adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: dependencies.readingProgressStore,
                    browsingHistoryStore: dependencies.browsingHistoryStore
                )
            ),
            migrateMangaTitleReferences: { oldName, newName in
                // Favorites no longer need a rename cascade here: a
                // `.mangaThread` favorite is keyed by the chapter's own
                // thread id, not by the directory's cleanBookName, so
                // renaming the directory can never change a favorite's
                // identity (smart-comic-mode Phase A decision #3/#9 —
                // `FavoriteLibraryDocument.renameMangaTitle` was removed
                // along with the merged-directory favorite mechanism it
                // served). Only the reading-progress side still has a
                // cleanBookName-keyed identity (the directory-level
                // `.mangaTitle` record, untouched by this refactor) and
                // needs migrating.
                do {
                    try await dependencies.readingProgressStore.migrateMangaTitleKey(from: oldName, to: newName)
                } catch {
                    YamiboLog.persistence.error("Failed to migrate reading progress key after manga title rename: \(error.localizedDescription)")
                }
            }
        )
    }
}

@MainActor
@Observable
public final class MangaReaderViewModel {
    // The properties below were `@Published` before the `@Observable`
    // migration; they stay tracked so the views keep re-rendering on the
    // exact same writes as before.
    public private(set) var presentation: MangaReaderPresentation
    public private(set) var applePencilPageTurnSettings = ApplePencilPageTurnSettings()
    public private(set) var chapterCommentsState: ReaderChapterCommentsState = .idle
    public private(set) var isLoadingMoreChapterComments = false
    public private(set) var chapterCommentsLoadMoreError: String?
    public private(set) var chapterCommentsRefreshError: String?
    public private(set) var likedPageIDs: Set<String> = []
    // Stays a tracked (observable) property on the view model (not on the
    // navigation coordinator) because MangaReaderView observes only this
    // object; the coordinator reads and writes it through its Reading
    // closures.
    private var navigationHistory = ReaderNavigationHistory<MangaReadingPosition>()

    public let context: MangaLaunchContext
    // Every `var` below was a plain (non-`@Published`) stored property
    // under `ObservableObject`, so writes to it never invalidated views;
    // `@ObservationIgnored` keeps that notification surface strictly
    // identical after the `@Observable` migration. The two task handles are
    // additionally *required* to be ignored: the nonisolated `deinit`
    // cancels them, and the macro would otherwise turn them into
    // main-actor-isolated computed properties unreachable from `deinit`.
    @ObservationIgnored private(set) var imageLoader: MangaReaderPageImageLoader?

    let dependencies: MangaReaderViewModelDependencies
    private let onReaderResumeRouteChange: ReaderResumeRouteChangeHandler
    @ObservationIgnored private var chapterCommentsRepository: ReaderChapterCommentsRepository?
    @ObservationIgnored private var workflow: MangaReaderWorkflow?
    @ObservationIgnored private var hasPrepared = false
    @ObservationIgnored private var committedSettings = MangaReaderSettings()
    @ObservationIgnored private var chapterJumpTask: Task<Void, Never>?
    @ObservationIgnored private var adjacentPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var readerContentGeneration = 0
    @ObservationIgnored private var currentStableReadingPosition: MangaReadingPosition?
    @ObservationIgnored private var lastQueuedProgressSnapshot: MangaReaderProgressSnapshot?
    @ObservationIgnored private var chapterJumpGeneration = 0
    @ObservationIgnored private var offlineCacheOwnerName: String?
    // The lazy module/coordinator references are ignored for the same
    // reason (never published) — and `lazy` storage cannot be rewritten
    // into the macro's tracked accessors anyway.
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
            }
        ),
        onChange: { [weak self] snapshot in
            // The module is driven exclusively from this main-actor view model,
            // so its caller-isolated onChange provably fires on the main actor.
            MainActor.assumeIsolated {
                self?.syncChapterComments(snapshot)
            }
        }
    )

    /// Wayfinding coordinator: sequences back/forward restores and records
    /// nonlinear jumps into `navigationHistory`. The restore itself stays
    /// here (`performNavigationRestoreAttempt`) because it republishes
    /// reader content.
    @ObservationIgnored private lazy var navigation = MangaReaderNavigationCoordinator(
        reading: MangaReaderNavigationCoordinator.Reading(
            navigationHistory: { [weak self] in self?.navigationHistory ?? ReaderNavigationHistory() },
            setNavigationHistory: { [weak self] navigationHistory in self?.navigationHistory = navigationHistory },
            stableReadingPosition: { [weak self] in self?.currentStableReadingPosition },
            restorePosition: { [weak self] targetPosition in
                await self?.performNavigationRestoreAttempt(to: targetPosition) ?? .aborted
            },
            scheduleAdjacentPrefetch: { [weak self] globalIndex in
                self?.scheduleAdjacentPrefetch(around: globalIndex)
            }
        )
    )

    /// Like module: owns like/unlike capture and the LikeStore change
    /// observation; `likedPageIDs` above is its published output.
    @ObservationIgnored private lazy var likeModule = MangaReaderLikeModule(
        reading: MangaReaderLikeModule.Reading(
            isSmartModeEnabled: context.isSmartModeEnabled,
            forumID: context.forumID,
            currentDirectoryCleanBookName: { [weak self] in self?.workflow?.currentDirectoryCleanBookName() },
            makeLikeDependencies: dependencies.makeLikeDependencies,
            imageSource: { [weak self] page in
                self?.imageSource(for: page) ?? page.mangaReaderImageSource(offlineScope: nil)
            },
            setLikedPageIDs: { [weak self] likedPageIDs in self?.likedPageIDs = likedPageIDs }
        )
    )

    /// Cover module: manual set/restore plus the mode-off automatic
    /// `.thread(tid:)` cover resolution after prepare.
    @ObservationIgnored private lazy var coverModule = MangaReaderCoverModule(
        reading: MangaReaderCoverModule.Reading(
            isSmartModeEnabled: context.isSmartModeEnabled,
            chapterTID: context.chapterTID,
            displayTitle: context.displayTitle,
            currentDirectoryCleanBookName: { [weak self] in self?.workflow?.currentDirectoryCleanBookName() },
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

    /// Session browsing-history row bookkeeping ("打开即记" plus mid-session
    /// identity re-records).
    @ObservationIgnored private lazy var browsingHistoryRecorder = MangaReaderBrowsingHistoryRecorder(
        context: context,
        reading: MangaReaderBrowsingHistoryRecorder.Reading(
            currentDirectoryFavoriteIdentity: { [weak self] in self?.workflow?.currentDirectoryFavoriteIdentity() },
            makeBrowsingHistoryStore: dependencies.makeBrowsingHistoryStore
        )
    )

    /// Directory command lane: update/search, reset, rename, chapter
    /// deletion, the automatic post-load update, and the panel countdowns.
    /// internal so the command forwarders in MangaReaderDirectoryLane.swift
    /// can reach it.
    @ObservationIgnored private(set) lazy var directoryLane = MangaReaderDirectoryLane(
        dependencies: dependencies,
        reader: MangaReaderDirectoryLane.Reader(
            workflow: { [weak self] in self?.workflow },
            presentation: { [weak self] in
                // The placeholder is unreachable in practice: the lane only
                // outlives the view model inside an already-guarded task,
                // and every lane path checks `workflow()` (nil by then).
                self?.presentation ?? MangaReaderPresentation(
                    state: .loading(MangaReaderLoadingPresentation(title: ""))
                )
            },
            setPresentation: { [weak self] presentation in self?.presentation = presentation },
            progressSnapshot: { [weak self] presentation in self?.progressSnapshot(from: presentation) },
            publishPresentation: { [weak self] nextPresentation, previousProgressSnapshot in
                self?.publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            },
            invalidateReaderContent: { [weak self] in self?.invalidateReaderContent() },
            offlineCacheOwnerName: { [weak self] in self?.offlineCacheOwnerName }
        )
    )

    deinit {
        // Only the handles this view model still owns; the extracted
        // modules (directory lane, like, cover) cancel their own task
        // handles in their own deinits. Both handles must stay
        // `@ObservationIgnored`: this nonisolated deinit could not touch
        // them if the `@Observable` macro rewrote them into tracked
        // (main-actor computed) properties.
        chapterJumpTask?.cancel()
        adjacentPrefetchTask?.cancel()
    }

    public convenience init(
        context: MangaLaunchContext,
        dependencies: MangaReaderDependencies,
        onReaderResumeRouteChange: @escaping ReaderResumeRouteChangeHandler = { _ in }
    ) {
        self.init(
            context: context,
            viewModelDependencies: MangaReaderViewModelDependencies(dependencies: dependencies),
            onReaderResumeRouteChange: onReaderResumeRouteChange
        )
    }

    init(
        context: MangaLaunchContext,
        viewModelDependencies: MangaReaderViewModelDependencies,
        onReaderResumeRouteChange: @escaping ReaderResumeRouteChangeHandler = { _ in }
    ) {
        self.context = context
        self.dependencies = viewModelDependencies
        self.onReaderResumeRouteChange = onReaderResumeRouteChange
        self.imageLoader = nil
        self.presentation = MangaReaderPresentation(
            state: .loading(MangaReaderLoadingPresentation(title: Self.presentationTitle(for: context)))
        )
    }

    // MARK: - Loading

    public func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        invalidateReaderContent()
        lastQueuedProgressSnapshot = nil

        let appSettings = await dependencies.settingsStore.load()
        committedSettings = Self.normalizedSettings(appSettings.manga)
        applePencilPageTurnSettings = appSettings.system.applePencilPageTurn
        presentation = presentationWithCommittedSettings(presentation)
        let imageLoader = MangaReaderPageImageLoader(
            imageSource: { [weak self] page in
                self?.imageSource(for: page) ?? page.mangaReaderImageSource(offlineScope: nil)
            }
        )
        // Directory search/tag filtering is scoped to the launching thread's
        // own board (pluggable-reader-config decision #6). The launch context
        // carries that board's fid; a context without one (likes, pre-forumID
        // persisted routes) falls back to "30" here — the single UI-side
        // fallback point (R4) — so such launches search exactly as they do
        // today. The time-related fields stay whatever the dependencies
        // provided (tests inject manual clocks through them).
        var directoryWorkflowConfiguration = dependencies.directoryWorkflowConfiguration
        directoryWorkflowConfiguration.searchForumID = context.forumID ?? "30"
        let workflow = MangaReaderWorkflow(
            context: context,
            projectionLoader: await dependencies.makeProjectionLoader(),
            directoryRepository: await dependencies.makeDirectoryRepository(),
            directoryStore: dependencies.makeDirectoryStore(),
            offlineCacheStore: dependencies.makeOfflineCacheStore(),
            settings: committedSettings,
            directoryWorkflowConfiguration: directoryWorkflowConfiguration,
            directorySearchCooldownState: dependencies.makeDirectorySearchCooldownState()
        )
        self.workflow = workflow
        self.imageLoader = imageLoader
        presentation = workflow.presentation
        presentation = await workflow.prepare()
        currentStableReadingPosition = stableReadingPosition(from: presentation)
        updateOfflineCacheOwnerName(from: presentation)
        directoryLane.refreshDirectoryPanelTiming(errorMessage: nil)
        if workflow.shouldAutoUpdateDirectoryAfterPrepare {
            directoryLane.startAutomaticDirectoryUpdate()
        }
        await likeModule.refreshLikedPageIDs()
        likeModule.observeLikeChangesIfNeeded()
        coverModule.startAutoThreadCoverResolutionIfNeeded()
        browsingHistoryRecorder.syncRecordIfNeeded(presentation: presentation)
    }

    public func retryInitialLoad() async {
        cancelReaderTasks()
        workflow = nil
        imageLoader = nil
        hasPrepared = false
        offlineCacheOwnerName = nil
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

    // MARK: - Page navigation

    public func updateCurrentPage(globalIndex: Int) {
        guard let workflow else { return }
        let previousGlobalIndex = currentPageIndex(in: presentation)
        adjacentPrefetchTask?.cancel()
        readerContentGeneration += 1
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

        adjacentPrefetchTask?.cancel()
        readerContentGeneration += 1
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        let nextPresentation = workflow.jumpToLoadedPage(at: targetPage.globalIndex)
        publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
        if navigation.isCurrentNavigationRequest(navigationGeneration) {
            navigation.recordSuccessfulNonlinearNavigation(from: sourcePosition, to: targetPosition)
        }
        scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? targetPage.globalIndex)
    }

    public func jumpRelativePage(_ delta: Int, usesTwoPageSpread: Bool) async {
        guard delta != 0,
              let workflow,
              presentation.settings.readingMode == .paged,
              case let .loaded(loaded) = presentation.state,
              !loaded.pages.isEmpty else {
            return
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
        guard let targetGlobalIndex else {
            await jumpToAdjacentChapterBoundary(
                delta: delta,
                sourcePosition: stableReadingPosition(from: loaded),
                workflow: workflow
            )
            return
        }

        adjacentPrefetchTask?.cancel()
        readerContentGeneration += 1
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        let nextPresentation = workflow.jumpToLoadedPage(at: targetGlobalIndex, animated: true)
        publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
        navigation.recordLinearReading(direction: delta >= 0 ? .forward : .backward)
        scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? targetGlobalIndex)
    }

    public func canJumpRelativePage(_ delta: Int, usesTwoPageSpread: Bool) -> Bool {
        guard delta != 0,
              let workflow,
              presentation.settings.readingMode == .paged,
              case let .loaded(loaded) = presentation.state,
              !loaded.pages.isEmpty else {
            return false
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
        if targetGlobalIndex != nil {
            return true
        }
        return workflow.canJumpToAdjacentChapter(
            from: stableReadingPosition(from: loaded),
            delta: delta
        )
    }

    /// Discrete adjacent-chapter jump for vertical mode, where page turning is
    /// continuous scrolling and the paged `jumpRelativePage` boundary path is
    /// unreachable. Shares its linear-crossing semantics: backward lands on
    /// the previous chapter's last page, forward on the next chapter's first.
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

    /// 打开原帖 target: the thread of the chapter currently on screen, not the
    /// launch context's `originalThreadID` — a smart manga directory spans
    /// many threads, so the entry chapter goes stale as soon as the reader
    /// crosses a chapter boundary. Anchors on the chapter's owner post
    /// (mirroring `NovelReaderViewModel.currentForumTargetURL`); before
    /// content loads there is no current page yet, so the launch thread keeps
    /// the button working from a loading/error screen.
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
        let scope = offlineCacheOwnerName.flatMap { ownerName in
            YamiboImageOfflineScope(tid: page.tid, ownerName: ownerName)
        }
        return page.mangaReaderImageSource(offlineScope: scope)
    }

    // MARK: - Manga cover

    // Thin forwarders: MangaReaderView's long-press action dialog and the
    // cover tests keep calling the model; MangaReaderCoverModule owns the
    // logic and the auto-resolution task.
    var canSetMangaCover: Bool {
        coverModule.canSetMangaCover
    }

    func hasManualMangaCover() async -> Bool {
        await coverModule.hasManualMangaCover()
    }

    func setMangaCover(page: MangaReaderPageProjection) async -> Bool {
        await coverModule.setMangaCover(page: page)
    }

    func restoreAutomaticMangaCover() async -> Bool {
        await coverModule.restoreAutomaticMangaCover()
    }

    // MARK: - Like

    // Thin forwarders: MangaReaderView and the likes sheet keep calling the
    // model; MangaReaderLikeModule owns the logic and the LikeStore change
    // observation.
    var canShowLikes: Bool {
        likeModule.canShowLikes
    }

    var likeSheetContext: (workKey: LikeWorkKey, like: LikeDependencies)? {
        likeModule.likeSheetContext
    }

    func likePage(_ page: MangaReaderPageProjection) async -> LikeCaptureOutcome? {
        await likeModule.likePage(page)
    }

    func isPageLiked(_ page: MangaReaderPageProjection) async -> LikeItem? {
        await likeModule.isPageLiked(page)
    }

    func unlikePage(_ item: LikeItem) async -> Bool {
        await likeModule.unlikePage(item)
    }

    // Returns false when there's no prepared workflow, so the caller can fall back to presenting a fresh reader.
    // This is a nonlinear jump like any other (`jumpToPage`, chapter directory), so it is recorded the same way,
    // making it eligible for the chrome's back/forward history. It stays on
    // the view model (not the Like module) because it is a reader-content
    // navigation that merely originates from the likes sheet.
    func jumpToLikedMangaPage(tid: String, localIndex: Int) async -> Bool {
        guard let workflow else { return false }
        let navigationGeneration = navigation.beginNavigationRequest()
        let sourcePosition = currentStableReadingPosition
        let targetPosition = MangaReadingPosition(tid: tid, localIndex: localIndex)
        adjacentPrefetchTask?.cancel()
        readerContentGeneration += 1
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

    // MARK: - Chapter comments

    public func loadChapterComments(for target: ReaderChapterCommentTarget?) async {
        await chapterCommentsModule.load(target)
    }

    public func refreshChapterComments(for target: ReaderChapterCommentTarget?) async {
        guard let target else { return }
        await chapterCommentsModule.refresh(target)
    }

    public func loadNextChapterCommentsPage() async {
        await chapterCommentsModule.loadNextPage()
    }

    // MARK: - Settings

    public func applySettings(_ settings: MangaReaderSettings) {
        let normalizedSettings = Self.normalizedSettings(settings)
        guard normalizedSettings != committedSettings else { return }

        committedSettings = normalizedSettings
        if let workflow {
            presentation = workflow.applySettings(normalizedSettings)
            directoryLane.refreshDirectoryPanelTiming(errorMessage: directoryLane.currentDirectoryPanelErrorMessage)
        } else {
            presentation = presentationWithCommittedSettings(presentation)
        }

        Task { [settingsStore = dependencies.settingsStore, normalizedSettings] in
            var appSettings = await settingsStore.load()
            appSettings.manga = normalizedSettings
            do {
                try await settingsStore.save(appSettings)
            } catch {
                YamiboLog.persistence.error("Failed to save manga reader settings: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Chapter jump and navigation history

    public func jumpToChapter(_ chapter: MangaChapter) async {
        chapterJumpTask?.cancel()
        invalidateReaderContent()
        chapterJumpGeneration += 1
        let generation = chapterJumpGeneration
        let navigationGeneration = navigation.beginNavigationRequest()
        let sourcePosition = currentStableReadingPosition
        chapterJumpTask = Task { @MainActor [weak self] in
            await self?.performJumpToChapter(
                chapter,
                sourcePosition: sourcePosition,
                navigationGeneration: navigationGeneration,
                jumpGeneration: generation
            )
        }
        await chapterJumpTask?.value
    }

    // Thin forwarders: the chrome and the navigation tests keep calling the
    // model; MangaReaderNavigationCoordinator owns history sequencing.
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
        jumpGeneration: Int
    ) async {
        guard let workflow else { return }
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        defer {
            if chapterJumpGeneration == jumpGeneration {
                chapterJumpTask = nil
            }
        }

        do {
            let nextPresentation = try await workflow.jumpToChapter(chapter)
            guard !Task.isCancelled, chapterJumpGeneration == jumpGeneration else { return }
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
            guard !Task.isCancelled, chapterJumpGeneration == jumpGeneration else { return }
            YamiboLog.reader.error("Jumping to manga chapter failed: \(error.localizedDescription)")
            directoryLane.refreshDirectoryPanelTiming(errorMessage: error.localizedDescription)
        }
    }

    @discardableResult
    // MARK: - Progress

    public func saveProgress() async -> MangaLaunchContext {
        guard let snapshot = progressSnapshot(from: presentation) else {
            return context
        }
        lastQueuedProgressSnapshot = snapshot
        guard !context.isPreview else {
            return snapshot.resumeContext
        }

        await onReaderResumeRouteChange(.manga(snapshot.resumeContext))
        do {
            try await dependencies.progressSync.flush(.manga(snapshot.progress))
        } catch {
            YamiboLog.sync.error("Failed to flush final manga reading progress on close: \(error.localizedDescription)")
        }
        return snapshot.resumeContext
    }

    // MARK: - Adjacent prefetch

    private func scheduleAdjacentPrefetch(around globalIndex: Int) {
        guard workflow != nil else { return }
        let generation = readerContentGeneration
        adjacentPrefetchTask = Task { @MainActor [weak self] in
            await self?.performAdjacentPrefetch(
                around: globalIndex,
                readerContentGeneration: generation
            )
        }
    }

    private func performAdjacentPrefetch(
        around globalIndex: Int,
        readerContentGeneration generation: Int
    ) async {
        guard let workflow else { return }
        defer {
            if readerContentGeneration == generation {
                adjacentPrefetchTask = nil
            }
        }

        let previousProgressSnapshot = progressSnapshot(from: presentation)
        guard let nextPresentation = await workflow.prefetchAdjacentChaptersIfNeeded(around: globalIndex) else {
            return
        }
        guard !Task.isCancelled, readerContentGeneration == generation else { return }
        publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
    }

    private func jumpToAdjacentChapterBoundary(
        delta: Int,
        sourcePosition: MangaReadingPosition?,
        workflow: MangaReaderWorkflow
    ) async {
        guard workflow.canJumpToAdjacentChapter(from: sourcePosition, delta: delta) else {
            return
        }

        adjacentPrefetchTask?.cancel()
        readerContentGeneration += 1
        let generation = readerContentGeneration
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        do {
            let nextPresentation = try await workflow.jumpToAdjacentChapter(
                from: sourcePosition,
                delta: delta,
                animated: true
            )
            guard !Task.isCancelled, readerContentGeneration == generation else { return }
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

    // MARK: - Reader content lifecycle and presentation publishing

    func invalidateReaderContent() {
        adjacentPrefetchTask?.cancel()
        adjacentPrefetchTask = nil
        readerContentGeneration += 1
    }

    private func cancelReaderTasks() {
        directoryLane.cancelTasks()
        chapterJumpTask?.cancel()
        chapterJumpTask = nil
        adjacentPrefetchTask?.cancel()
        adjacentPrefetchTask = nil
        likeModule.cancelObservation()
        coverModule.cancelAutoThreadCoverResolution()
        readerContentGeneration += 1
    }

    func publishPresentation(
        _ nextPresentation: MangaReaderPresentation,
        previousProgressSnapshot: MangaReaderProgressSnapshot?
    ) {
        if nextPresentation != presentation {
            presentation = nextPresentation
        }
        updateOfflineCacheOwnerName(from: nextPresentation)
        currentStableReadingPosition = stableReadingPosition(from: nextPresentation)
        // Directory identity/title can change through any presentation
        // update (automatic directory update, rename); identity-stable
        // updates early-return on the record-key check inside.
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
        let progressSync = dependencies.progressSync
        Task { [onReaderResumeRouteChange, snapshot, progressSync] in
            await onReaderResumeRouteChange(.manga(snapshot.resumeContext))
            await progressSync.queue(.manga(snapshot.progress))
        }
    }

    private func updateOfflineCacheOwnerName(from presentation: MangaReaderPresentation) {
        guard case let .loaded(loaded) = presentation.state else {
            offlineCacheOwnerName = nil
            return
        }
        offlineCacheOwnerName = Self.normalizedDirectoryName(loaded.directoryTitle)
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

    /// One attempt of a back/forward restore, on behalf of the navigation
    /// coordinator: moves reader content to `targetPosition` and reports
    /// how the attempt ended. Lives here (not on the coordinator) because a
    /// restore is a reader-content republish — prefetch cancellation,
    /// content generation, and presentation publishing are this view
    /// model's own lifecycle.
    private func performNavigationRestoreAttempt(
        to targetPosition: MangaReadingPosition
    ) async -> MangaReaderNavigationCoordinator.RestoreAttemptOutcome {
        guard let workflow else { return .aborted }
        adjacentPrefetchTask?.cancel()
        readerContentGeneration += 1
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        do {
            let nextPresentation = try await workflow.jumpToPosition(targetPosition)
            publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            return .restored(prefetchIndex: currentPageIndex(in: nextPresentation) ?? 0)
        } catch is CancellationError {
            return .aborted
        } catch {
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
            offlineCacheFavoriteID: context.offlineCacheFavoriteID,
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

    // static (like `normalizedNonEmpty` below) so the browsing-history
    // recorder can share the exact same normalization instead of keeping a
    // drifting copy.
    static func normalizedDirectoryName(_ directoryName: String?) -> String? {
        let normalized = directoryName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private func ensureChapterCommentsRepository() async throws -> ReaderChapterCommentsRepository {
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
        chapterCommentsRefreshError = snapshot.refreshError
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

    static func normalizedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

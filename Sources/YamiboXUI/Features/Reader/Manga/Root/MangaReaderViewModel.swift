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
public final class MangaReaderViewModel: ObservableObject {
    // internal(set): the +Directory extension file republishes presentation.
    @Published public internal(set) var presentation: MangaReaderPresentation
    @Published public private(set) var applePencilPageTurnSettings = ApplePencilPageTurnSettings()
    @Published public private(set) var chapterCommentsState: ReaderChapterCommentsState = .idle
    @Published public private(set) var isLoadingMoreChapterComments = false
    @Published public private(set) var chapterCommentsLoadMoreError: String?
    @Published public private(set) var chapterCommentsRefreshError: String?
    @Published public private(set) var likedPageIDs: Set<String> = []
    @Published private var navigationHistory = ReaderNavigationHistory<MangaReadingPosition>()
    private var linearReadingHistoryExpiration = ReaderNavigationLinearReadingExpiration<MangaReadingPosition>()

    public let context: MangaLaunchContext
    private(set) var imageLoader: MangaReaderPageImageLoader?

    let dependencies: MangaReaderViewModelDependencies
    private let onReaderResumeRouteChange: ReaderResumeRouteChangeHandler
    private var chapterCommentsRepository: ReaderChapterCommentsRepository?
    var workflow: MangaReaderWorkflow?
    private var hasPrepared = false
    private var committedSettings = MangaReaderSettings()
    // Directory lane state, owned by MangaReaderViewModel+Directory.swift.
    var directoryCooldownExpiresAt: Date?
    var forcedSearchShortcutExpiresAt: Date?
    var directoryTickTask: Task<Void, Never>?
    var directoryMutationTask: Task<Void, Never>?
    var automaticDirectoryUpdateTask: Task<Void, Never>?
    private var chapterJumpTask: Task<Void, Never>?
    private var adjacentPrefetchTask: Task<Void, Never>?
    private var readerContentGeneration = 0
    private var navigationRequestGeneration = 0
    private var currentStableReadingPosition: MangaReadingPosition?
    private var lastQueuedProgressSnapshot: MangaReaderProgressSnapshot?
    var directoryMutationGeneration = 0
    private var chapterJumpGeneration = 0
    var offlineCacheOwnerName: String?
    private var likeChangeObservationTask: Task<Void, Never>?
    private var autoThreadCoverResolutionTask: Task<Void, Never>?
    /// `"\(entry.id)|\(entry.title)"` of the last browsing-history row this
    /// session recorded — re-records when the directory identity or title
    /// changes mid-session (synthetic directory resolving into a real one,
    /// or an in-reader rename), absorbing the superseded row by its old id.
    private var recordedBrowsingHistoryKey: String?
    private var recordedBrowsingHistoryEntryID: String?
    private lazy var chapterCommentsModule = ReaderChapterCommentsModule(
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

    deinit {
        directoryTickTask?.cancel()
        directoryMutationTask?.cancel()
        automaticDirectoryUpdateTask?.cancel()
        chapterJumpTask?.cancel()
        adjacentPrefetchTask?.cancel()
        likeChangeObservationTask?.cancel()
        autoThreadCoverResolutionTask?.cancel()
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
        refreshDirectoryPanelTiming(errorMessage: nil)
        if workflow.shouldAutoUpdateDirectoryAfterPrepare {
            startAutomaticDirectoryUpdate()
        }
        await refreshLikedPageIDs()
        observeLikeChangesIfNeeded()
        startAutoThreadCoverResolutionIfNeeded()
        syncBrowsingHistoryRecordIfNeeded()
    }

    /// Records this session's browsing-history row once `.loaded` (decision
    /// #5's "打开即记"), then keeps the row's *identity* in sync: the
    /// directory identity can change mid-session (a synthetic
    /// single-chapter directory resolving into a real one via the automatic
    /// update, or an in-reader rename), and the debounced
    /// `updatePosition` refreshes would otherwise target a row id that no
    /// longer matches — freezing the old row and spawning a duplicate on
    /// the next open. Re-recording under the new identity absorbs the
    /// superseded row by its old id. Called from `prepare()` and from
    /// `publishPresentation` (identity-stable page turns early-return on the
    /// key check).
    ///
    /// Identity forks on `context.isSmartModeEnabled` — never on a proxy
    /// signal like a non-nil directory name, which a mode-off
    /// pseudo-directory also produces (the trap three smart-comic-mode
    /// phases each hit once):
    /// - Mode on: one directory-level `.mangaTitle` row per manga (decision
    ///   #2), absorbing the directory members' single-thread rows (decision
    ///   #13) — the loaded directory panel has the member list.
    /// - Mode off: this thread's own `.mangaThread` row, exactly like a
    ///   normal post (smart-comic-mode "mode off = plain thread" principle).
    /// Position/chapter refreshes ride the debounced progress saves via
    /// `FavoriteLibraryProgressSyncAdapter`. Preview sessions never record.
    private func syncBrowsingHistoryRecordIfNeeded() {
        guard !context.isPreview,
              case let .loaded(loaded) = presentation.state else {
            return
        }
        let currentPage = loaded.currentPage
        let entry: BrowsingHistoryEntry
        let absorbedThreadIDs: [String]
        if context.isSmartModeEnabled {
            let cleanBookName = normalizedDirectoryName(loaded.directoryTitle)
                ?? normalizedDirectoryName(context.directoryName)
                ?? context.displayTitle
            let target = FavoriteContentTarget(
                mangaID: workflow?.currentDirectoryFavoriteIdentity() ?? cleanBookName,
                mangaCleanBookName: cleanBookName
            )
            entry = BrowsingHistoryEntry(
                target: target,
                title: cleanBookName,
                forumID: context.forumID,
                pageIndex: currentPage?.localIndex,
                pageCount: currentPage?.chapterPageCount,
                chapterTitle: currentPage?.chapterTitle,
                chapterThreadID: currentPage?.tid ?? context.chapterTID,
                lastVisitTime: .now
            )
            absorbedThreadIDs = loaded.directoryPanel.displayChapters.map(\.tid)
        } else {
            entry = BrowsingHistoryEntry(
                target: .mangaThread(threadID: context.chapterTID),
                title: context.displayTitle,
                forumID: context.forumID,
                pageIndex: currentPage?.localIndex,
                pageCount: currentPage?.chapterPageCount,
                chapterTitle: currentPage?.chapterTitle,
                lastVisitTime: .now
            )
            absorbedThreadIDs = []
        }

        let recordKey = "\(entry.id)|\(entry.title)"
        guard recordKey != recordedBrowsingHistoryKey else { return }
        let supersededEntryID = recordedBrowsingHistoryEntryID.flatMap { $0 == entry.id ? nil : $0 }
        recordedBrowsingHistoryKey = recordKey
        recordedBrowsingHistoryEntryID = entry.id
        guard let browsingHistoryStore = dependencies.makeBrowsingHistoryStore() else { return }
        Task {
            do {
                try await browsingHistoryStore.record(
                    entry,
                    absorbingThreadIDs: absorbedThreadIDs,
                    absorbingEntryIDs: supersededEntryID.map { [$0] } ?? []
                )
            } catch {
                YamiboLog.reader.warning("Failed to record manga browsing-history visit for \(entry.id, privacy: .public): \(error)")
            }
        }
    }

    public func retryInitialLoad() async {
        cancelReaderTasks()
        workflow = nil
        imageLoader = nil
        hasPrepared = false
        offlineCacheOwnerName = nil
        resetNavigationHistory()
        currentStableReadingPosition = nil
        lastQueuedProgressSnapshot = nil
        recordedBrowsingHistoryKey = nil
        recordedBrowsingHistoryEntryID = nil
        directoryCooldownExpiresAt = nil
        forcedSearchShortcutExpiresAt = nil
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
        recordLinearReadingForNavigationHistory(direction: direction)
        scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? globalIndex)
    }

    public func jumpToPage(localIndex: Int) async {
        guard let workflow,
              case let .loaded(loaded) = presentation.state,
              let currentPage = loaded.currentPage else {
            return
        }
        let navigationGeneration = beginNavigationRequest()
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
        if isCurrentNavigationRequest(navigationGeneration) {
            recordSuccessfulNonlinearNavigation(from: sourcePosition, to: targetPosition)
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
        recordLinearReadingForNavigationHistory(direction: delta >= 0 ? .forward : .backward)
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

    func imageSource(for page: MangaReaderPageProjection) -> YamiboImageSource {
        let scope = offlineCacheOwnerName.flatMap { ownerName in
            YamiboImageOfflineScope(tid: page.tid, ownerName: ownerName)
        }
        return page.mangaReaderImageSource(offlineScope: scope)
    }

    // MARK: - Manga cover

    private var mangaCoverKey: ContentCoverKey? {
        // Smart Comic Mode off (design decisions #2's 总原则 and #16): this
        // chapter is read exactly like a normal thread, so the cover entry
        // writes the same `.thread(tid:)` key `ImageBrowserCoverActions`
        // uses for a normal thread's "设为封面" action, keyed by this
        // chapter's own thread id. This branches on `context
        // .isSmartModeEnabled` directly rather than, say, whether
        // `workflow?.currentDirectoryCleanBookName()` happens to be
        // non-nil — the mode-off synthesized single-chapter pseudo-
        // directory (`MangaReaderWorkflow.standaloneDirectory`) has a
        // non-nil cleanBookName too, which is exactly the proxy-signal trap
        // that caused the Like-feature and AppContinuityWorkflow bugs in
        // earlier phases.
        guard context.isSmartModeEnabled else {
            return .thread(tid: context.chapterTID)
        }
        guard let cleanBookName = workflow?.currentDirectoryCleanBookName()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !cleanBookName.isEmpty else {
            return nil
        }
        return .smartManga(cleanBookName: cleanBookName)
    }

    var canSetMangaCover: Bool {
        mangaCoverKey != nil && dependencies.makeContentCoverStore() != nil
    }

    func hasManualMangaCover() async -> Bool {
        guard let key = mangaCoverKey, let store = dependencies.makeContentCoverStore() else { return false }
        return await store.cover(for: key)?.manualCoverURL != nil
    }

    func setMangaCover(page: MangaReaderPageProjection) async -> Bool {
        guard let key = mangaCoverKey, let store = dependencies.makeContentCoverStore() else { return false }
        do {
            try await store.setManualCover(imageSource(for: page).url, for: key)
            return true
        } catch {
            YamiboLog.library.error("Failed to set manual manga cover: \(error.localizedDescription)")
            return false
        }
    }

    func restoreAutomaticMangaCover() async -> Bool {
        guard let key = mangaCoverKey, let store = dependencies.makeContentCoverStore() else { return false }
        do {
            try await store.clearManualCover(for: key)
            return true
        } catch {
            YamiboLog.library.error("Failed to clear manual manga cover: \(error.localizedDescription)")
            return false
        }
    }

    /// Smart Comic Mode off (design decisions #2's 总原则 and #16): this
    /// chapter is read exactly like a normal thread, so it gets the same
    /// automatic `.thread(tid:)` cover resolution `ForumThreadReaderViewModel`
    /// already performs for normal threads — reusing the same
    /// `ThreadCoverResolver` mechanism. `ForumThreadReaderViewModel` hangs its
    /// call off adding the thread to favorites (it has no other lifecycle
    /// hook); the manga reader has no favorite-toggle action of its own, so
    /// opening the reader (a successful `prepare()`) is its closest
    /// equivalent trigger. Like that reference call site, this doesn't check
    /// for an existing cover first — it unconditionally overwrites the
    /// automatic cover, same as `setAutomaticCover` always does.
    ///
    /// Mode-on chapters never do this: their cover comes from the existing
    /// smartManga backfill mechanism elsewhere (design decision #13, a later
    /// phase), not from the reader itself.
    private func startAutoThreadCoverResolutionIfNeeded() {
        guard !context.isSmartModeEnabled,
              case .loaded = presentation.state,
              autoThreadCoverResolutionTask == nil else {
            return
        }
        autoThreadCoverResolutionTask = Task { @MainActor [weak self] in
            await self?.performAutoThreadCoverResolution()
        }
    }

    private func performAutoThreadCoverResolution() async {
        defer { autoThreadCoverResolutionTask = nil }
        guard let coverStore = dependencies.makeContentCoverStore(),
              let repository = await dependencies.makeThreadCoverPageRepository() else {
            return
        }
        let tid = context.chapterTID
        guard let coverCandidate = await ThreadCoverResolver().resolve(
            thread: ThreadIdentity(tid: tid),
            title: context.displayTitle,
            repository: repository
        ) else {
            return
        }
        do {
            _ = try await coverStore.setAutomaticCover(coverCandidate, for: .thread(tid: tid))
        } catch {
            YamiboLog.library.error("Failed to set automatic cover for manga chapter thread \(tid) while Smart Comic Mode is off: \(error.localizedDescription)")
        }
    }

    // MARK: - Like

    private var likeWorkKey: LikeWorkKey? {
        // Smart Comic Mode off means this chapter is treated exactly like a normal thread
        // (see smart-comic-mode-design-decisions #2's 总原则) — the reader's directory in that
        // state is a synthesized single-chapter stand-in (MangaReaderWorkflow.standaloneDirectory),
        // not a real MangaDirectory, so it must not be usable as a manga-title Like identity.
        guard context.isSmartModeEnabled else { return nil }
        guard let cleanBookName = workflow?.currentDirectoryCleanBookName()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !cleanBookName.isEmpty else {
            return nil
        }
        return .mangaTitle(cleanBookName: cleanBookName)
    }

    var canShowLikes: Bool {
        likeWorkKey != nil && dependencies.makeLikeDependencies() != nil
    }

    var likeSheetContext: (workKey: LikeWorkKey, like: LikeDependencies)? {
        guard let workKey = likeWorkKey, let like = dependencies.makeLikeDependencies() else { return nil }
        return (workKey, like)
    }

    func likePage(_ page: MangaReaderPageProjection) async -> LikeCaptureOutcome? {
        guard let workKey = likeWorkKey, let like = dependencies.makeLikeDependencies() else { return nil }
        let anchor = MangaImageLikeAnchor(chapterTID: page.tid, pageLocalIndex: page.localIndex, forumID: context.forumID)
        let source = imageSource(for: page)
        let service = MangaImageLikeCaptureService(likeStore: like.likeStore, likeImageStore: like.likeImageStore)
        let outcome = try? await service.like(
            workKey: workKey,
            anchor: anchor,
            sourceImageURL: source.url,
            imageData: { try await YamiboImagePipeline.shared.data(for: source) }
        )
        await refreshLikedPageIDs()
        return outcome
    }

    // Returns the existing Like Item for this page, if any, so the long-press
    // action sheet can offer "remove like" instead of "add to likes".
    func isPageLiked(_ page: MangaReaderPageProjection) async -> LikeItem? {
        guard let workKey = likeWorkKey, let like = dependencies.makeLikeDependencies() else { return nil }
        let items = await like.likeStore.likes(for: workKey)
        return items.first { item in
            guard case let .mangaImage(anchor) = item.anchor else { return false }
            return anchor.chapterTID == page.tid && anchor.pageLocalIndex == page.localIndex
        }
    }

    func unlikePage(_ item: LikeItem) async -> Bool {
        guard let like = dependencies.makeLikeDependencies() else { return false }
        do {
            // Terminal write: shield against the long-press confirmation dialog's
            // Task being cancelled mid-delete (e.g. the user closes the reader).
            try await Task {
                try await like.likeStore.delete(id: item.id)
                try await like.likeImageStore.delete(id: item.id)
            }.value
        } catch {
            return false
        }
        await refreshLikedPageIDs()
        return true
    }

    private func refreshLikedPageIDs() async {
        guard let workKey = likeWorkKey, let like = dependencies.makeLikeDependencies() else {
            likedPageIDs = []
            return
        }
        let items = await like.likeStore.likes(for: workKey)
        likedPageIDs = Set(items.compactMap { item -> String? in
            guard case let .mangaImage(anchor) = item.anchor else { return nil }
            return "\(anchor.chapterTID)#\(anchor.pageLocalIndex)"
        })
    }

    private func observeLikeChangesIfNeeded() {
        guard likeChangeObservationTask == nil, let like = dependencies.makeLikeDependencies() else { return }
        let changeID = like.likeStore.changeID
        likeChangeObservationTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: LikeStore.didChangeNotification) {
                guard let receivedChangeID = notification.userInfo?[LikeStore.changeIDUserInfoKey] as? String,
                      receivedChangeID == changeID else {
                    continue
                }
                await self?.refreshLikedPageIDs()
            }
        }
    }

    // Returns false when there's no prepared workflow, so the caller can fall back to presenting a fresh reader.
    // This is a nonlinear jump like any other (`jumpToPage`, chapter directory), so it is recorded the same way,
    // making it eligible for the chrome's back/forward history.
    func jumpToLikedMangaPage(tid: String, localIndex: Int) async -> Bool {
        guard let workflow else { return false }
        let navigationGeneration = beginNavigationRequest()
        let sourcePosition = currentStableReadingPosition
        let targetPosition = MangaReadingPosition(tid: tid, localIndex: localIndex)
        adjacentPrefetchTask?.cancel()
        readerContentGeneration += 1
        let previousProgressSnapshot = progressSnapshot(from: presentation)
        do {
            let nextPresentation = try await workflow.jumpToPosition(targetPosition)
            publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
            if isCurrentNavigationRequest(navigationGeneration) {
                recordSuccessfulNonlinearNavigation(from: sourcePosition, to: targetPosition)
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
            refreshDirectoryPanelTiming(errorMessage: currentDirectoryPanelErrorMessage)
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
        let navigationGeneration = beginNavigationRequest()
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

    public var canNavigateBack: Bool {
        currentStableReadingPosition != nil && navigationHistory.canGoBack
    }

    public var canNavigateForward: Bool {
        currentStableReadingPosition != nil && navigationHistory.canGoForward
    }

    public func navigateBack() async {
        await restoreNavigationAnchor(direction: .back)
    }

    public func navigateForward() async {
        await restoreNavigationAnchor(direction: .forward)
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
            if isCurrentNavigationRequest(navigationGeneration) {
                recordSuccessfulNonlinearNavigation(
                    from: sourcePosition,
                    to: MangaReadingPosition(tid: chapter.tid, localIndex: 0)
                )
            }
            refreshDirectoryPanelTiming(errorMessage: nil)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, chapterJumpGeneration == jumpGeneration else { return }
            YamiboLog.reader.error("Jumping to manga chapter failed: \(error.localizedDescription)")
            refreshDirectoryPanelTiming(errorMessage: error.localizedDescription)
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
            recordLinearReadingForNavigationHistory(direction: delta >= 0 ? .forward : .backward)
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

    private func beginNavigationRequest() -> Int {
        navigationRequestGeneration += 1
        return navigationRequestGeneration
    }

    private func isCurrentNavigationRequest(_ generation: Int) -> Bool {
        navigationRequestGeneration == generation
    }

    private func cancelReaderTasks() {
        directoryTickTask?.cancel()
        directoryTickTask = nil
        directoryMutationTask?.cancel()
        directoryMutationTask = nil
        automaticDirectoryUpdateTask?.cancel()
        automaticDirectoryUpdateTask = nil
        chapterJumpTask?.cancel()
        chapterJumpTask = nil
        adjacentPrefetchTask?.cancel()
        adjacentPrefetchTask = nil
        likeChangeObservationTask?.cancel()
        likeChangeObservationTask = nil
        autoThreadCoverResolutionTask?.cancel()
        autoThreadCoverResolutionTask = nil
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
        syncBrowsingHistoryRecordIfNeeded()
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
        offlineCacheOwnerName = normalizedDirectoryName(loaded.directoryTitle)
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

    private enum NavigationRestoreDirection {
        case back
        case forward
    }

    private func restoreNavigationAnchor(direction: NavigationRestoreDirection) async {
        guard let sourcePosition = currentStableReadingPosition else { return }
        let navigationGeneration = beginNavigationRequest()

        while let targetPosition = navigationTarget(for: direction) {
            guard let workflow else { return }
            adjacentPrefetchTask?.cancel()
            readerContentGeneration += 1
            let previousProgressSnapshot = progressSnapshot(from: presentation)
            do {
                let nextPresentation = try await workflow.jumpToPosition(targetPosition)
                publishPresentation(nextPresentation, previousProgressSnapshot: previousProgressSnapshot)
                guard isCurrentNavigationRequest(navigationGeneration) else { return }
                commitNavigationRestore(direction: direction, sourcePosition: sourcePosition)
                scheduleAdjacentPrefetch(around: currentPageIndex(in: nextPresentation) ?? 0)
                return
            } catch is CancellationError {
                return
            } catch {
                YamiboLog.reader.warning("Restoring manga navigation history target failed, discarding and trying next: \(error.localizedDescription)")
                guard isCurrentNavigationRequest(navigationGeneration) else { return }
                discardNavigationTarget(for: direction)
            }
        }
    }

    private func navigationTarget(for direction: NavigationRestoreDirection) -> MangaReadingPosition? {
        switch direction {
        case .back:
            navigationHistory.peekBack()
        case .forward:
            navigationHistory.peekForward()
        }
    }

    private func commitNavigationRestore(
        direction: NavigationRestoreDirection,
        sourcePosition: MangaReadingPosition
    ) {
        switch direction {
        case .back:
            navigationHistory.commitBack(from: sourcePosition)
        case .forward:
            navigationHistory.commitForward(from: sourcePosition)
        }
        armLinearReadingHistoryExpirationIfNeeded()
    }

    private func discardNavigationTarget(for direction: NavigationRestoreDirection) {
        switch direction {
        case .back:
            navigationHistory.discardBackCandidate()
        case .forward:
            navigationHistory.discardForwardCandidate()
        }
        resetLinearReadingHistoryExpirationIfHistoryIsEmpty()
    }

    private func recordSuccessfulNonlinearNavigation(
        from sourcePosition: MangaReadingPosition?,
        to targetPosition: MangaReadingPosition
    ) {
        guard let sourcePosition, sourcePosition != targetPosition else { return }
        navigationHistory.recordNonlinearJump(from: sourcePosition, to: targetPosition)
        armLinearReadingHistoryExpirationIfNeeded()
    }

    private func recordLinearReadingForNavigationHistory(direction: ReaderNavigationLinearReadingDirection) {
        guard navigationHistory.canGoBack || navigationHistory.canGoForward else {
            linearReadingHistoryExpiration.reset()
            return
        }
        guard let position = currentStableReadingPosition else { return }
        if linearReadingHistoryExpiration.recordLinearReading(at: position, direction: direction) {
            navigationHistory.clear()
        }
    }

    private func armLinearReadingHistoryExpirationIfNeeded() {
        guard navigationHistory.canGoBack || navigationHistory.canGoForward,
              let position = currentStableReadingPosition else {
            linearReadingHistoryExpiration.reset()
            return
        }
        linearReadingHistoryExpiration.arm(at: position)
    }

    private func resetNavigationHistory() {
        navigationHistory = ReaderNavigationHistory()
        linearReadingHistoryExpiration.reset()
    }

    private func resetLinearReadingHistoryExpirationIfHistoryIsEmpty() {
        guard !navigationHistory.canGoBack, !navigationHistory.canGoForward else { return }
        linearReadingHistoryExpiration.reset()
    }

    func progressSnapshot(from presentation: MangaReaderPresentation) -> MangaReaderProgressSnapshot? {
        guard case let .loaded(loaded) = presentation.state,
              let currentPage = loaded.currentPage else {
            return nil
        }

        let directoryName = normalizedDirectoryName(loaded.directoryTitle) ?? normalizedDirectoryName(context.directoryName)
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

    private func normalizedDirectoryName(_ directoryName: String?) -> String? {
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

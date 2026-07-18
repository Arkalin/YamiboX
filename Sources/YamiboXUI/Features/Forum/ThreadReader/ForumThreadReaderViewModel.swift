import Foundation
import Observation
import YamiboXCore

protocol ForumThreadPageLoading: Sendable {
    func cachedThreadPage(context: ThreadNovelLaunchContext, page: Int) async -> ForumThreadPage?
    func fetchThreadPage(context: ThreadNovelLaunchContext, page: Int) async throws -> ForumThreadPage
    func fetchRatingResults(threadID: String, postID: String) async throws -> ForumThreadRatingResultsPage
    func fetchRateOptions(threadID: String, postID: String) async throws -> ForumThreadRateOptionsPage
    func fetchPollVoters(threadID: String, optionID: String?, page: Int) async throws -> ForumThreadPollVotersPage
    func votePoll(forumID: String, threadID: String, optionIDs: [String], formHash: String) async throws -> String
    func ratePost(
        threadID: String,
        postID: String,
        score: Int,
        reason: String,
        formHash: String,
        noticeAuthor: Bool
    ) async throws -> String
    func commentPost(threadID: String, postID: String, message: String, formHash: String, page: Int) async throws -> String
}

extension ForumThreadReaderRepository: ForumThreadPageLoading {}

@MainActor
@Observable
final class ForumThreadReaderViewModel {
    var page: ForumThreadPage?
    var currentPage = 1
    var isLoading = false
    var errorMessage: String?
    var transientMessage: String?
    var isFavorited = false
    var favoriteErrorMessage: String?
    var favoriteAddPromptPresented = false
    var favoriteRemovePrompt: FavoriteRemovePrompt?
    var favoriteLocationPickerContext: FavoriteLocationPickerContext?
    @ObservationIgnored private var pendingFavoriteLocations: [FavoriteLocation]?
    /// Floor anchor loaded from saved reading progress, pending its one
    /// restore scroll (browsing-history decision #8). The body view scrolls
    /// to it once the page renders, then calls `consumeRestoredAnchor()`.
    /// While non-nil, incoming visible-anchor updates are ignored so the
    /// initial top-of-page render can't overwrite the saved anchor before
    /// the restore scroll happens.
    var restoredAnchorPostID: String?

    let context: ThreadNovelLaunchContext

    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any ForumThreadPageLoading
    @ObservationIgnored private let localFavoriteLibraryStoreProvider: @Sendable () async -> FavoriteLibraryStore?
    @ObservationIgnored private let readingProgressStoreProvider: @Sendable () async -> ReadingProgressStore?
    @ObservationIgnored private let browsingHistoryStoreProvider: @Sendable () async -> BrowsingHistoryStore?
    @ObservationIgnored private let favoriteRepositoryProvider: @Sendable () async -> (any ForumThreadFavoriteRemoteOperating)?
    @ObservationIgnored private let contentCoverStoreProvider: @Sendable () async -> ContentCoverStore?
    @ObservationIgnored private let mangaDirectoryStoreProvider: @Sendable () async -> (any MangaDirectoryPersisting)?
    @ObservationIgnored private let settingsStoreProvider: @Sendable () async -> SettingsStore?
    @ObservationIgnored private let progressSync: ProgressSyncModule?
    @ObservationIgnored private var latestVisibleAnchorPostID: String?
    @ObservationIgnored private var generation = 0

    init(context: ThreadNovelLaunchContext, dependencies: ForumDependencies) {
        self.context = context
        repositoryProvider = {
            await dependencies.makeForumThreadReaderRepository()
        }
        localFavoriteLibraryStoreProvider = {
            dependencies.localFavoriteLibraryStore
        }
        readingProgressStoreProvider = {
            dependencies.readingProgressStore
        }
        browsingHistoryStoreProvider = {
            dependencies.browsingHistoryStore
        }
        favoriteRepositoryProvider = {
            await dependencies.makeFavoriteRepository()
        }
        contentCoverStoreProvider = {
            dependencies.contentCoverStore
        }
        mangaDirectoryStoreProvider = {
            dependencies.mangaDirectoryStore
        }
        settingsStoreProvider = {
            dependencies.settingsStore
        }
        progressSync = ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(
                readingProgressStore: dependencies.readingProgressStore,
                browsingHistoryStore: dependencies.browsingHistoryStore
            )
        )
    }

    init(
        context: ThreadNovelLaunchContext,
        repository: any ForumThreadPageLoading,
        localFavoriteLibraryStore: FavoriteLibraryStore? = nil,
        readingProgressStore: ReadingProgressStore? = nil,
        browsingHistoryStore: BrowsingHistoryStore? = nil,
        favoriteRepository: (any ForumThreadFavoriteRemoteOperating)? = nil,
        contentCoverStore: ContentCoverStore? = nil,
        mangaDirectoryStore: (any MangaDirectoryPersisting)? = nil,
        settingsStore: SettingsStore? = nil
    ) {
        self.context = context
        repositoryProvider = {
            repository
        }
        localFavoriteLibraryStoreProvider = {
            localFavoriteLibraryStore
        }
        readingProgressStoreProvider = {
            readingProgressStore
        }
        browsingHistoryStoreProvider = {
            browsingHistoryStore
        }
        favoriteRepositoryProvider = {
            favoriteRepository
        }
        contentCoverStoreProvider = {
            contentCoverStore
        }
        mangaDirectoryStoreProvider = {
            mangaDirectoryStore
        }
        settingsStoreProvider = {
            settingsStore
        }
        progressSync = readingProgressStore.map { progressStore in
            ProgressSyncModule(
                adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: progressStore,
                    browsingHistoryStore: browsingHistoryStore
                )
            )
        }
    }

    var navigationTitle: String {
        page?.title ?? context.title
    }

    /// Cover menu entries for images opened from this thread: thread cover
    /// always, manga cover when the thread is a chapter of a local directory
    /// and its board currently has Smart Comic Mode on (design decision
    /// #16 — mode off hides this entry outright, even if a `MangaDirectory`
    /// technically still exists for this tid).
    var imageBrowserCoverActionsProvider: ImageBrowserCoverActionsProvider {
        let forumID = resolvedForumID
        return ImageBrowserThreadCoverActions.provider(
            tid: context.thread.tid,
            contentCoverStore: contentCoverStoreProvider,
            mangaDirectoryStore: mangaDirectoryStoreProvider,
            isSmartComicModeEnabled: { [settingsStoreProvider] in
                // Strict rule, no special cases: without a settings store
                // there is no configured smart-enabled manga board, so the
                // manga-cover entry stays hidden.
                guard let settingsStore = await settingsStoreProvider() else { return false }
                return await settingsStore.load().isSmartComicModeEnabled(forumID: forumID)
            }
        )
    }

    var pageNavigation: ForumPageNavigation? {
        page?.pageNavigation
    }

    var targetPostID: String? {
        context.targetPostID
    }

    func load() async {
        guard page == nil else { return }
        await refreshFavoriteState()
        var initialPage = context.initialPage
        // Every entrance restores the saved position (browsing-history
        // decision #8) unless the launch carries an explicit deep-link
        // target — a specific post or a specific page wins over resume.
        if context.targetPostID == nil, context.initialPage <= 1,
           let progressStore = await readingProgressStoreProvider(),
           let savedProgress = await progressStore.load(for: .normalThread(threadID: context.thread.tid))?.thread {
            initialPage = max(1, savedProgress.lastPage)
            restoredAnchorPostID = savedProgress.anchorPostID
        }
        await loadPage(initialPage)
    }

    func refresh() async {
        await loadPage(
            currentPage,
            preferCache: false,
            preservesCurrentContentOnFailure: true,
            usesCachedFallbackOnFailure: true
        )
    }

    func retry() {
        Task {
            await refresh()
        }
    }

    func goToPage(_ page: Int) async {
        let nextPage = max(1, page)
        guard nextPage != currentPage else { return }
        await loadPage(nextPage)
    }

    func clearFavoriteError() {
        favoriteErrorMessage = nil
    }

    func clearTransientMessage() {
        transientMessage = nil
    }

    /// Routes the star button through the remembered add/remove sync choices:
    /// either performs the action silently or raises the matching prompt.
    func toggleFavorite() async {
        let settings = await favoriteSettings()
        if let favoriteItem = await localFavoriteItem(forThreadID: context.thread.tid) {
            let favorite = favoriteItem.favorite(type: .other)
            let canRemoveRemote = await favoriteRepositoryProvider() != nil
                && favorite.remoteFavoriteID?.isEmpty == false
            switch FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote) {
            case .prompt:
                favoriteRemovePrompt = FavoriteRemovePrompt(favorite: favorite)
            case let .silent(removeRemote):
                await performFavoriteRemoval(favorite, removeRemote: removeRemote)
            }
            return
        }

        let canSyncRemote = await favoriteRepositoryProvider() != nil
        switch FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: canSyncRemote) {
        case .prompt:
            favoriteAddPromptPresented = true
        case let .silent(syncToRemote):
            await performFavoriteAdd(syncToRemote: syncToRemote)
        }
    }

    func confirmFavoriteAdd(syncToRemote: Bool, remember: Bool) async {
        favoriteAddPromptPresented = false
        if remember {
            await rememberAddSyncChoice(syncToRemote)
        }
        await performFavoriteAdd(syncToRemote: syncToRemote)
    }

    func confirmFavoriteRemoval(_ favorite: Favorite, removeRemote: Bool, remember: Bool) async {
        favoriteRemovePrompt = nil
        if remember {
            await rememberRemoveRemoteChoice(removeRemote)
        }
        await performFavoriteRemoval(favorite, removeRemote: removeRemote)
    }

    /// Star button long-press: opens the location picker pre-filled with
    /// this item's current locations (empty if not yet favorited).
    func presentFavoriteLocationPicker() async {
        guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else { return }
        let document = (try? await localFavoriteLibraryStore.load()) ?? FavoriteLibraryDocument()
        let currentLocations = await localFavoriteItem(forThreadID: context.thread.tid)?.locations ?? []
        favoriteLocationPickerContext = FavoriteLocationPickerContext(
            document: document,
            initialSelection: Set(currentLocations),
            isFavorited: isFavorited,
            localFavoriteLibraryStore: localFavoriteLibraryStore
        )
    }

    /// Routes the picker's confirmed selection: not-yet-favorited creates
    /// with those locations (still subject to the add-sync prompt); already
    /// favorited with a non-empty selection re-pins locally; already
    /// favorited with everything cleared is treated as unfavoriting, through
    /// the normal remove-sync decision — mirroring Android.
    func confirmFavoriteLocationSelection(_ locations: Set<FavoriteLocation>) async {
        favoriteLocationPickerContext = nil
        guard let favoriteItem = await localFavoriteItem(forThreadID: context.thread.tid) else {
            guard !locations.isEmpty else { return }
            pendingFavoriteLocations = Array(locations)
            let settings = await favoriteSettings()
            let canSyncRemote = await favoriteRepositoryProvider() != nil
            switch FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: canSyncRemote) {
            case .prompt:
                favoriteAddPromptPresented = true
            case let .silent(syncToRemote):
                await performFavoriteAdd(syncToRemote: syncToRemote)
            }
            return
        }
        let favorite = favoriteItem.favorite(type: .other)
        guard !locations.isEmpty else {
            let settings = await favoriteSettings()
            let canRemoveRemote = await favoriteRepositoryProvider() != nil
                && favorite.remoteFavoriteID?.isEmpty == false
            switch FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote) {
            case .prompt:
                favoriteRemovePrompt = FavoriteRemovePrompt(favorite: favorite)
            case let .silent(removeRemote):
                await performFavoriteRemoval(favorite, removeRemote: removeRemote)
            }
            return
        }
        await performFavoriteRelocate(Array(locations))
    }

    private func performFavoriteAdd(syncToRemote: Bool) async {
        let locations = pendingFavoriteLocations
        pendingFavoriteLocations = nil
        do {
            guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else {
                throw YamiboPersistenceError(context: "Local favorite library store is unavailable")
            }
            let result = try await FavoriteQuickActions.addFavorite(
                threadID: context.thread.tid,
                title: favoriteTitle,
                type: .other,
                authorID: nil,
                forumID: resolvedForumID,
                forumName: page?.forumName,
                contentUpdatedAt: Self.contentUpdatedAt(from: page),
                locations: locations,
                formHash: page?.formHash,
                syncToRemote: syncToRemote,
                boardReaderSettings: await boardReaderSettings(),
                localFavoriteLibraryStore: localFavoriteLibraryStore,
                remoteRepository: await favoriteRepositoryProvider()
            )
            if let coverCandidate = ThreadCoverResolver.findThreadCoverCandidate(in: page),
               let coverStore = await contentCoverStoreProvider() {
                do {
                    _ = try await coverStore.setAutomaticCover(coverCandidate, for: .thread(tid: context.thread.tid))
                } catch {
                    YamiboLog.library.error("Failed to set automatic cover for thread \(self.context.thread.tid) during favorite add: \(error)")
                }
            }
            isFavorited = true
            if let directoryTitle = await autoAttributionDirectoryTitle(localFavoriteLibraryStore: localFavoriteLibraryStore) {
                transientMessage = L10n.string("favorites.quick.auto_attributed", result.remote.addFeedbackMessage, directoryTitle)
            } else {
                transientMessage = result.remote.addFeedbackMessage
            }
        } catch {
            favoriteErrorMessage = error.localizedDescription
            await refreshFavoriteState()
        }
    }

    private func performFavoriteRemoval(_ favorite: Favorite, removeRemote: Bool) async {
        do {
            guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else {
                throw YamiboPersistenceError(context: "Local favorite library store is unavailable")
            }
            try await FavoriteQuickActions.removeFavorite(
                favorite,
                removeRemote: removeRemote,
                boardReaderSettings: await boardReaderSettings(),
                localFavoriteLibraryStore: localFavoriteLibraryStore,
                remoteRepository: await favoriteRepositoryProvider()
            )
            isFavorited = false
            transientMessage = removeRemote
                ? L10n.string("favorites.quick.removed_with_remote")
                : L10n.string("favorites.quick.removed")
        } catch {
            favoriteErrorMessage = error.localizedDescription
            await refreshFavoriteState()
        }
    }

    private func performFavoriteRelocate(_ locations: [FavoriteLocation]) async {
        do {
            guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else {
                throw YamiboPersistenceError(context: "Local favorite library store is unavailable")
            }
            try await FavoriteQuickActions.relocateFavorite(
                threadID: context.thread.tid,
                locations: locations,
                localFavoriteLibraryStore: localFavoriteLibraryStore
            )
            transientMessage = L10n.string("favorites.quick.relocated")
        } catch {
            favoriteErrorMessage = error.localizedDescription
        }
    }

    /// Local half of decision #8's "auto-attribution" feedback (the
    /// remote-sync half is a later phase) — the star-button add path is the
    /// most common way users hit this feature, so it gets an immediate toast
    /// rather than waiting for a sync warning that may never come.
    ///
    /// Fires only when every one of these holds, checked in this order so
    /// the cheapest gate runs first:
    /// - This board's Smart Comic Mode is on, via an explicit
    ///   `settingsStore` lookup (never inferred from a proxy signal like
    ///   "a directory happened to resolve" — that exact mistake bit three
    ///   earlier smart-comic-mode phases).
    /// - A `MangaDirectory` actually resolves for this tid (a single-tid
    ///   `directory(containingTID:)` lookup is enough here — this is one
    ///   favorite, not the batch grouping the favorites page does).
    /// - At least one *other* already-favorited `.mangaThread` item (the one
    ///   just added is already persisted by the time this runs) shares that
    ///   directory's chapter tids.
    ///
    /// Returns the directory's `cleanBookName` to interpolate into the toast,
    /// or nil to leave `transientMessage` as the plain add-feedback string.
    private func autoAttributionDirectoryTitle(localFavoriteLibraryStore: FavoriteLibraryStore) async -> String? {
        guard let settingsStore = await settingsStoreProvider() else { return nil }
        let settings = await settingsStore.load()
        guard settings.isSmartComicModeEnabled(forumID: resolvedForumID) else { return nil }
        guard let mangaDirectoryStore = await mangaDirectoryStoreProvider(),
              let directory = try? await mangaDirectoryStore.directory(containingTID: context.thread.tid) else {
            return nil
        }
        let siblingTIDs = Set(directory.chapters.map(\.tid))
        guard let document = try? await localFavoriteLibraryStore.load() else { return nil }
        // A sibling favorite only actually merges on the Favorites page if ITS
        // OWN board also has Smart Comic Mode on (LocalFavoriteLibraryProjection's
        // rawGroupedFavorites checks isSmartComicModeEnabled(forumID:) per-member, not just for
        // the item just favorited) — a MangaDirectory can span threads from
        // different boards (e.g. a `.searched` strategy match isn't fid-scoped).
        // Without this check the toast could claim "merged" for a sibling that
        // the Favorites page will actually keep standalone.
        let hasOtherFavoriteInDirectory = document.items.contains { item in
            item.target.kind == .mangaThread
                && item.target.threadID != context.thread.tid
                && siblingTIDs.contains(item.target.threadID ?? "")
                && settings.isSmartComicModeEnabled(forumID: item.forumID)
        }
        guard hasOtherFavoriteInDirectory else { return nil }
        return directory.cleanBookName
    }

    private func favoriteSettings() async -> FavoriteLibrarySettings {
        guard let settingsStore = await settingsStoreProvider() else {
            return FavoriteLibrarySettings()
        }
        return await settingsStore.load().favorites
    }

    private func boardReaderSettings() async -> BoardReaderSettings {
        guard let settingsStore = await settingsStoreProvider() else {
            return BoardReaderSettings()
        }
        return await settingsStore.load().boardReader
    }

    private func rememberAddSyncChoice(_ syncToRemote: Bool) async {
        guard let settingsStore = await settingsStoreProvider() else { return }
        await FavoriteQuickActions.rememberAddSyncChoice(syncToRemote, settingsStore: settingsStore)
    }

    private func rememberRemoveRemoteChoice(_ removeRemote: Bool) async {
        guard let settingsStore = await settingsStoreProvider() else { return }
        await FavoriteQuickActions.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore)
    }

    func loadRatingResults(postID: String) async throws -> ForumThreadRatingResultsPage {
        let repository = await repositoryProvider()
        return try await repository.fetchRatingResults(threadID: threadID, postID: postID)
    }

    func loadRateOptions(postID: String) async throws -> ForumThreadRateOptionsPage {
        let repository = await repositoryProvider()
        return try await repository.fetchRateOptions(threadID: threadID, postID: postID)
    }

    func loadPollVoters(optionID: String?, page: Int) async throws -> ForumThreadPollVotersPage {
        let repository = await repositoryProvider()
        return try await repository.fetchPollVoters(threadID: threadID, optionID: optionID, page: page)
    }

    func votePoll(optionIDs: [String]) async throws -> String {
        guard let forumID = normalizedForumID, let formHash = normalizedFormHash else {
            throw YamiboError.underlying(L10n.string("forum.thread.login_info_failed"))
        }
        let repository = await repositoryProvider()
        let message = try await repository.votePoll(
            forumID: forumID,
            threadID: threadID,
            optionIDs: optionIDs,
            formHash: formHash
        )
        await refresh()
        return message
    }

    func ratePost(
        postID: String,
        score: Int,
        reason: String,
        noticeAuthor: Bool
    ) async throws -> String {
        guard let formHash = normalizedFormHash else {
            throw YamiboError.underlying(L10n.string("forum.thread.login_info_failed"))
        }
        let repository = await repositoryProvider()
        let message = try await repository.ratePost(
            threadID: threadID,
            postID: postID,
            score: score,
            reason: reason,
            formHash: formHash,
            noticeAuthor: noticeAuthor
        )
        await refresh()
        return message
    }

    func commentPost(postID: String, message: String) async throws -> String {
        guard let formHash = normalizedFormHash else {
            throw YamiboError.underlying(L10n.string("forum.thread.login_info_failed"))
        }
        let repository = await repositoryProvider()
        let result = try await repository.commentPost(
            threadID: threadID,
            postID: postID,
            message: message,
            formHash: formHash,
            page: currentPage
        )
        await refresh()
        return result
    }

    func imageBrowserRequest(
        imageID: String,
        url: URL,
        title: String?,
        refererURL: URL
    ) -> ForumThreadImageBrowserRequest? {
        guard let page else { return nil }
        let defaultTitle = L10n.string("forum.thread.image")
        let gallery = ForumThreadImageBrowserGallery(
            page: page,
            refererURL: refererURL,
            selectedBlockID: imageID,
            defaultTitle: defaultTitle
        )
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackItem = ImageBrowserItem(
            id: imageID,
            source: YamiboImageSource(url: url, refererPageURL: refererURL),
            title: trimmedTitle.isEmpty ? defaultTitle : trimmedTitle
        )
        return ForumThreadImageBrowserRequest(
            items: gallery.items.isEmpty ? [fallbackItem] : gallery.items,
            initialItemID: gallery.initialItemID ?? fallbackItem.id
        )
    }

    private var threadID: String {
        page?.thread.tid ?? context.thread.tid
    }

    /// Best-known forum id for this thread, falling back from the freshest
    /// loaded page down to the launch context — used wherever a forumID is
    /// needed opportunistically (favorite add, cover-action mode gating)
    /// rather than requiring the page to already be loaded.
    private var resolvedForumID: String? {
        page?.forumID ?? page?.thread.fid ?? context.thread.fid
    }

    private var normalizedForumID: String? {
        normalized(page?.forumID)
    }

    private var normalizedFormHash: String? {
        normalized(page?.formHash)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadPage(
        _ page: Int,
        preferCache: Bool = true,
        preservesCurrentContentOnFailure: Bool = false,
        usesCachedFallbackOnFailure: Bool = false
    ) async {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        transientMessage = nil
        defer {
            if requestGeneration == generation {
                isLoading = false
            }
        }
        let previousLoadedPage = self.page == nil ? nil : currentPage

        do {
            let repository = await repositoryProvider()
            let loaded = if preferCache, let cached = await repository.cachedThreadPage(context: context, page: page) {
                cached
            } else {
                try await repository.fetchThreadPage(context: context, page: page)
            }
            guard requestGeneration == generation else { return }
            self.page = loaded
            currentPage = loaded.pageNavigation?.currentPage ?? page
            handlePageLoadSuccess(previousLoadedPage: previousLoadedPage)
        } catch {
            guard requestGeneration == generation else { return }
            let repository = await repositoryProvider()
            if usesCachedFallbackOnFailure,
               let cached = await repository.cachedThreadPage(context: context, page: page) {
                guard requestGeneration == generation else { return }
                self.page = cached
                currentPage = cached.pageNavigation?.currentPage ?? page
                errorMessage = nil
                transientMessage = L10n.string("forum.thread.refresh_failed", error.localizedDescription)
                handlePageLoadSuccess(previousLoadedPage: previousLoadedPage)
                return
            }

            guard requestGeneration == generation else { return }
            if preservesCurrentContentOnFailure, self.page != nil {
                errorMessage = nil
                transientMessage = L10n.string("forum.thread.refresh_failed", error.localizedDescription)
            } else {
                self.page = nil
                currentPage = page
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Reading progress + browsing history

    /// Reported by the body view whenever the topmost rendered post changes
    /// (floor-level anchor capture). Ignored while a restored anchor is
    /// still pending its scroll, so the initial top-of-page render can't
    /// clobber the saved position before the restore happens.
    func updateVisibleAnchor(postID: String?) {
        guard restoredAnchorPostID == nil else { return }
        guard latestVisibleAnchorPostID != postID else { return }
        latestVisibleAnchorPostID = postID
        guard postID != nil else { return }
        queueReadingProgressSave()
    }

    func consumeRestoredAnchor() {
        // Seed the live anchor from the restored one so leaving without
        // scrolling doesn't flush a nil anchor over the saved position.
        if latestVisibleAnchorPostID == nil {
            latestVisibleAnchorPostID = restoredAnchorPostID
        }
        restoredAnchorPostID = nil
    }

    /// Exit-time write-through, called from the view's `onDisappear`. Runs
    /// in a fresh unstructured Task so view teardown can't cancel the GRDB
    /// write mid-flight (the cancelled-Task write trap).
    func flushReadingProgress() {
        guard let progressSync, page != nil else { return }
        let position = currentThreadReadingPosition()
        Task {
            do {
                try await progressSync.flush(.thread(position))
            } catch {
                YamiboLog.forum.warning("Failed to flush normal-thread reading progress on exit; next visit resumes from the last debounced save: \(error)")
            }
        }
    }

    private func handlePageLoadSuccess(previousLoadedPage: Int?) {
        if previousLoadedPage != currentPage {
            // A different page renders different posts; the old anchor is
            // meaningless there. Same-page reloads (refresh) keep it — the
            // visible cards re-report momentarily anyway.
            latestVisibleAnchorPostID = nil
        }
        recordBrowsingHistoryVisit()
        queueReadingProgressSave()
    }

    private func queueReadingProgressSave() {
        guard let progressSync, page != nil else { return }
        let position = currentThreadReadingPosition()
        Task {
            await progressSync.queue(.thread(position))
        }
    }

    private func currentThreadReadingPosition() -> ThreadReadingPosition {
        ThreadReadingPosition(
            threadID: context.thread.tid,
            page: currentPage,
            pageCount: pageNavigation?.totalPages,
            anchorPostID: latestVisibleAnchorPostID ?? restoredAnchorPostID
        )
    }

    /// Upserts this visit's history row on every successful page load
    /// (browsing-history decision #5: open records, page turns refresh).
    /// Discussion companion views never record (decision #14) — their tid
    /// belongs to the novel/manga main-form row.
    private func recordBrowsingHistoryVisit() {
        guard !context.isDiscussionView, page != nil else { return }
        let entry = BrowsingHistoryEntry(
            target: .normalThread(threadID: context.thread.tid),
            title: favoriteTitle,
            forumID: resolvedForumID,
            pageIndex: currentPage,
            pageCount: pageNavigation?.totalPages,
            lastVisitTime: .now
        )
        Task { [browsingHistoryStoreProvider] in
            guard let store = await browsingHistoryStoreProvider() else { return }
            do {
                try await store.record(entry)
            } catch {
                YamiboLog.forum.warning("Failed to record browsing-history visit for \(entry.id, privacy: .public): \(error)")
            }
        }
    }

    private var favoriteTitle: String {
        let loadedTitle = page?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !loadedTitle.isEmpty {
            return loadedTitle
        }
        let contextTitle = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return contextTitle.isEmpty ? context.thread.tid : contextTitle
    }

    private static func contentUpdatedAt(from page: ForumThreadPage?) -> Date? {
        guard let firstPost = page?.posts.first else { return nil }
        return FavoriteContentUpdateDateResolver.date(
            lastEditedText: firstPost.lastEditedText,
            postedAtText: firstPost.postedAtText
        )
    }

    private func refreshFavoriteState() async {
        isFavorited = await localFavoriteItem(forThreadID: context.thread.tid) != nil
    }

    private func localFavoriteItem(forThreadID threadID: String) async -> FavoriteItem? {
        guard let localFavoriteLibraryStore = await localFavoriteLibraryStoreProvider() else { return nil }
        let target = FavoriteItemTarget.normalThread(threadID: threadID)
        return (try? await localFavoriteLibraryStore.load())?.items.first { item in
            item.target.id == target.id || item.target.threadID == target.threadID
        }
    }
}


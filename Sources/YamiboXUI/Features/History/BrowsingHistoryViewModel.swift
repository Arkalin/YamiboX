import Foundation
import Observation
import YamiboXCore

/// Timeline and work-level favorite membership share one canonical snapshot.
@MainActor
@Observable
final class BrowsingHistoryViewModel {
    let showsPreviousReading: Bool
    var entries: [BrowsingHistoryEntry] = []
    var selectedCategory: BrowsingHistoryCategory?
    /// The configuration snapshot used to canonicalize the displayed rows.
    private(set) var boardReaderSettings = BoardReaderSettings()
    private(set) var showsNormalThreadProgress = false
    var searchText = ""
    var isLoading = false
    var hasLoaded = false
    private(set) var favoriteSnapshot: FavoriteMembershipSnapshot?
    private(set) var favoritesReady = false
    private(set) var smartMangaBulkDeleteEnabled = true
    var favoriteActions: FavoriteActionController?
    var coverSourcesByEntryID: [String: YamiboImageSource] = [:]
    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    var errorDetails: LoadFailureDetails?
    var transientFeedback: TransientFeedback?
    var transientMessage: String? {
        get { transientFeedback?.message }
        set { transientFeedback = newValue.map { TransientFeedback(message: $0) } }
    }
    var clearAllConfirmationPresented = false
    var clearAllMessage = L10n.string("history.clear_all.message")

    func prepareClearAllConfirmation() async {
        let notice = await browsingHistoryStore.deletionNotice()
        clearAllMessage = L10n.string("history.clear_all.message") + "\n\n" + notice
        clearAllConfirmationPresented = true
    }

    @ObservationIgnored private let browsingHistoryStore: BrowsingHistoryStore
    @ObservationIgnored private let browsingHistoryWorkflow: BrowsingHistoryWorkflow
    @ObservationIgnored private let favoriteLibraryStore: FavoriteLibraryStore
    @ObservationIgnored private let mangaDirectoryStore: any MangaDirectoryPersisting
    @ObservationIgnored private let contentCoverStore: ContentCoverStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let makeFavoriteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    @ObservationIgnored private let openTargetResolver: BrowsingHistoryOpenTargetResolver
    /// Debounces the reload storms this page is exposed to: store change
    /// signals fire every ~350ms while a reader opened from here keeps
    /// saving positions. Search has a separate in-memory filter debounce.
    @ObservationIgnored private var pendingReloadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFilterTask: Task<Void, Never>?
    @ObservationIgnored private var unfilteredEntries: [BrowsingHistoryEntry] = []
    /// Drops stale reload results when a newer reload has since started.
    @ObservationIgnored private var reloadGeneration = 0

    init(dependencies: BrowsingHistoryDependencies, showsPreviousReading: Bool = false) {
        self.showsPreviousReading = showsPreviousReading
        browsingHistoryStore = dependencies.browsingHistoryStore
        browsingHistoryWorkflow = dependencies.browsingHistoryWorkflow
        favoriteLibraryStore = dependencies.localFavoriteLibraryStore
        mangaDirectoryStore = dependencies.mangaDirectoryStore
        contentCoverStore = dependencies.contentCoverStore
        settingsStore = dependencies.settingsStore
        makeFavoriteRepository = dependencies.makeFavoriteRepository
        openTargetResolver = BrowsingHistoryOpenTargetResolver(
            readingProgressStore: dependencies.readingProgressStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            historyWorkflow: dependencies.browsingHistoryWorkflow
        )
    }

    func load() async {
        isLoading = entries.isEmpty
        defer {
            isLoading = false
            hasLoaded = true
        }
        await reload()
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let settings = await settingsStore.load()
        let snapshot: BrowsingHistorySnapshot
        let favorites: FavoriteMembershipSnapshot
        do {
            snapshot = try await browsingHistoryWorkflow.snapshot()
            favorites = try await FavoriteMembershipSnapshot.load(
                libraryStore: favoriteLibraryStore, directoryStore: mangaDirectoryStore,
                boardReader: snapshot.boardReader,
                additionalThreadIDs: snapshot.entries.map { FavoriteMembershipScope(entry: $0, boardReader: snapshot.boardReader).threadID }
            )
        } catch {
            guard generation == reloadGeneration,
                  !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
            favoritesReady = false
            errorMessage = error.localizedDescription
            errorDetails = LoadFailureDetails(error: error)
            return
        }
        let boardReader = snapshot.boardReader
        let loadedEntries = snapshot.entries
        guard generation == reloadGeneration, !Task.isCancelled else { return }
        favoriteSnapshot = favorites
        if !favoritesReady { errorMessage = nil }
        favoritesReady = true
        smartMangaBulkDeleteEnabled = settings.favorites.smartMangaBulkDeleteEnabled
        boardReaderSettings = boardReader
        showsNormalThreadProgress = settings.readingProgress.savesNormalThreadProgress
        let scopedEntries = showsPreviousReading
            ? BookshelfShelf(entries: loadedEntries, boardReader: boardReader, favorites: settings.system.homeShowsOnlyFavorites ? favorites : nil).readingEntries
            : loadedEntries
        unfilteredEntries = scopedEntries
        applyFilter()
        await refreshCovers(for: scopedEntries, generation: generation)
    }

    func applyFilter() {
        let searchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = unfilteredEntries.filter { entry in
            if !searchQuery.isEmpty,
               !entry.title.localizedStandardContains(searchQuery) { return false }
            guard let selectedCategory else { return true }
            return entry.category(boardReader: boardReaderSettings) == selectedCategory
        }
    }

    func scheduleFilter() {
        pendingFilterTask?.cancel()
        pendingFilterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.applyFilter()
        }
    }

    func effectiveCategory(for entry: BrowsingHistoryEntry) -> BrowsingHistoryCategory {
        entry.category(boardReader: boardReaderSettings)
    }

    /// Coalesces reload triggers behind a short debounce; `reload()` itself
    /// stays available for the initial load and explicit user actions.
    func scheduleReload() {
        pendingReloadTask?.cancel()
        pendingReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Follows history-store changes (recording readers, deletes from this
    /// page) and favorite-library changes (heart state) for the lifetime of
    /// the page. No changeID guards in these three observers, as before:
    /// every change through the instances this page holds should refresh it,
    /// its own writes included.
    func observeHistoryChanges() async {
        for await _ in browsingHistoryStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func observeFavoriteChanges() async {
        for await _ in favoriteLibraryStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    /// Reload through the workflow so configuration, identity and position
    /// change together, including when the page stays in the navigation stack.
    func observeSettingsChanges() async {
        for await _ in settingsStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func delete(_ entry: BrowsingHistoryEntry) async {
        reloadGeneration += 1
        unfilteredEntries.removeAll { $0.id == entry.id }
        entries.removeAll { $0.id == entry.id }
        do {
            try await browsingHistoryWorkflow.delete(entry)
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            await reload()
        }
    }

    func clearAll() async {
        reloadGeneration += 1
        unfilteredEntries = []
        entries = []
        do {
            try await browsingHistoryStore.clearAllForSync()
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            await reload()
        }
    }

    func openTarget(for entry: BrowsingHistoryEntry) async -> BrowsingHistoryOpenTarget? {
        do {
            return try await openTargetResolver.openTarget(for: entry)
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return nil
        }
    }

    // MARK: - Favorite actions

    func favoriteThreadID(for entry: BrowsingHistoryEntry) -> String? {
        entry.target.threadID ?? entry.chapterThreadID ?? entry.lastVisitedThreadID
    }

    func isFavorited(_ entry: BrowsingHistoryEntry) -> Bool {
        favoriteSnapshot?.membership(for: entry).isFavorited == true
    }

    func favoriteLabel(for entry: BrowsingHistoryEntry) -> String {
        guard favoritesReady else { return L10n.string(errorMessage == nil ? "common.loading" : "common.load_failed") }
        if let membership = favoriteSnapshot?.membership(for: entry), membership.isFavorited, membership.isSmartManga {
            return L10n.string(smartMangaBulkDeleteEnabled ? "favorites.work.remove" : "favorites.view_archived_favorites")
        }
        return L10n.string(isFavorited(entry) ? "history.favorite.remove" : "history.favorite.add")
    }

    func toggleFavorite(_ entry: BrowsingHistoryEntry) async {
        guard let actions = makeActions(for: entry) else { return }
        favoriteActions = actions
        await actions.toggleFavorite()
    }

    func presentFavoriteLocationPicker(_ entry: BrowsingHistoryEntry) async {
        guard let actions = makeActions(for: entry) else { return }
        favoriteActions = actions
        await actions.presentLocationPicker()
    }

    private func makeActions(for entry: BrowsingHistoryEntry) -> FavoriteActionController? {
        guard favoritesReady, favoriteActions?.isWorking != true,
              let tid = favoriteThreadID(for: entry) else { return nil }
        let title: String
        if entry.target.kind == .mangaTitle, let chapter = entry.chapterTitle, chapter != entry.title {
            title = "\(entry.title) \(chapter)"
        } else { title = entry.title }
        let actions = FavoriteActionController(
            threadID: tid, type: .other, defaultTitle: title,
            localFavoriteLibraryStore: favoriteLibraryStore, settingsStore: settingsStore,
            makeFavoriteRepository: makeFavoriteRepository,
            scope: FavoriteMembershipScope(entry: entry, boardReader: boardReaderSettings),
            mangaDirectoryStore: mangaDirectoryStore
        )
        let settingsStore = settingsStore
        actions.makeAddMetadata = {
            let settings = await settingsStore.load()
            return .init(
                title: title, authorID: entry.authorID, forumID: entry.forumID,
                localTargetKindOverride: entry.category(boardReader: settings.boardReader).favoriteTargetKind
            )
        }
        return actions
    }

    func observeDirectoryChanges() async {
        for await _ in mangaDirectoryStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func clearTransientMessage() { transientMessage = nil }
    func clearError() { errorMessage = nil }

    private func refreshCovers(for entries: [BrowsingHistoryEntry], generation: Int) async {
        var keysByEntryID: [String: ContentCoverKey] = [:]
        for entry in entries {
            if let key = ContentCoverKey(target: entry.target) {
                keysByEntryID[entry.id] = key
            }
        }
        let coversByKey = await contentCoverStore.covers(for: Array(keysByEntryID.values))
        guard generation == reloadGeneration else { return }
        var covers: [String: YamiboImageSource] = [:]
        for (entryID, key) in keysByEntryID {
            if let url = coversByKey[key]?.resolvedImageSource {
                covers[entryID] = url
            }
        }
        coverSourcesByEntryID = covers
    }
}

extension BrowsingHistoryCategory {
    /// Favorite target kind a row of this (effective) category stamps when
    /// hearted — the display/open category and the favorited identity must
    /// never disagree.
    var favoriteTargetKind: FavoriteItemTargetKind {
        switch self {
        case .normal:
            .normalThread
        case .novel:
            .novelThread
        case .manga:
            .mangaThread
        }
    }
}

import Foundation
import Observation
import YamiboXCore

/// Drives the browsing-history page: timeline entries with type filtering
/// and title search, per-row covers, and the quick-favorite heart.
///
/// The heart acts on "the thread this row currently points at" — for a
/// directory-level manga row that is the current chapter, never the whole
/// merged group (browsing-history decision #11: a light tap stays a light
/// action). Add/remove reuse the standard quick-action decision flow
/// (remembered sync choices raise the same prompts the reader's star button
/// does).
@MainActor
@Observable
final class BrowsingHistoryViewModel {
    var entries: [BrowsingHistoryEntry] = []
    var selectedCategory: BrowsingHistoryCategory?
    /// Snapshot of the per-board reader configuration taken at reload time —
    /// rows display and filter by their *effective* category (the board's
    /// current 阅读方式, falling back to the recorded identity;
    /// pluggable-reader-config R13), so the chip a row appears under always
    /// matches the reader it would open with.
    private(set) var boardReaderSettings = BoardReaderSettings()
    var searchText = ""
    var isLoading = false
    var hasLoaded = false
    var favoritedThreadIDs: Set<String> = []
    var coverURLsByEntryID: [String: URL] = [:]
    var errorMessage: String?
    var transientMessage: String?
    var favoriteAddPromptPresented = false
    var favoriteRemovePrompt: FavoriteRemovePrompt?
    var favoriteLocationPickerContext: FavoriteLocationPickerContext?
    var clearAllConfirmationPresented = false

    @ObservationIgnored private let browsingHistoryStore: BrowsingHistoryStore?
    @ObservationIgnored private let favoriteLibraryStore: FavoriteLibraryStore
    @ObservationIgnored private let contentCoverStore: ContentCoverStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    @ObservationIgnored private let openTargetResolver: BrowsingHistoryOpenTargetResolver
    /// The entry whose heart raised the currently presented add prompt.
    @ObservationIgnored private var pendingFavoriteAddEntry: BrowsingHistoryEntry?
    /// The entry whose heart long-press raised `favoriteLocationPickerContext`.
    @ObservationIgnored private var pendingFavoriteLocationEntry: BrowsingHistoryEntry?
    /// Locations picked in `favoriteLocationPickerContext`, consumed by the
    /// next `performFavoriteAdd` — set only by
    /// `confirmFavoriteLocationSelection`, so a plain (non-long-press) heart
    /// tap still falls through to `addFavorite`'s default-category behavior.
    @ObservationIgnored private var pendingFavoriteLocations: [FavoriteLocation]?
    /// Debounces the reload storms this page is exposed to: store change
    /// signals fire every ~350ms while a reader opened from here keeps
    /// saving positions, and the search field fires per keystroke.
    @ObservationIgnored private var pendingReloadTask: Task<Void, Never>?
    /// Drops stale reload results when a newer reload has since started.
    @ObservationIgnored private var reloadGeneration = 0

    init(dependencies: LibraryDependencies) {
        browsingHistoryStore = dependencies.browsingHistoryStore
        favoriteLibraryStore = dependencies.localFavoriteLibraryStore
        contentCoverStore = dependencies.contentCoverStore
        settingsStore = dependencies.settingsStore
        makeFavoriteRepository = dependencies.makeFavoriteRepository
        openTargetResolver = BrowsingHistoryOpenTargetResolver(
            readingProgressStore: dependencies.readingProgressStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore
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
        guard let browsingHistoryStore else {
            entries = []
            return
        }
        reloadGeneration += 1
        let generation = reloadGeneration
        let searchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The persisted `category` column holds the recorded identity; the
        // chip filter must match by *effective* category instead (board
        // configuration can remap rows after the fact), so category
        // filtering happens here rather than in SQL.
        let boardReader = await settingsStore.load().boardReader
        let loadedEntries = await browsingHistoryStore.entries(
            category: nil,
            searchText: searchQuery.isEmpty ? nil : searchQuery
        )
        guard generation == reloadGeneration else { return }
        boardReaderSettings = boardReader
        entries = loadedEntries.filter { entry in
            guard let selectedCategory else { return true }
            return entry.category(boardReader: boardReader) == selectedCategory
        }
        await refreshFavoritedThreadIDs()
        await refreshCovers(for: entries, generation: generation)
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
        // A nil store means the history feature is disabled and nothing can
        // ever write through it, so there is no change source to follow.
        guard let browsingHistoryStore else { return }
        for await _ in browsingHistoryStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func observeFavoriteChanges() async {
        for await _ in favoriteLibraryStore.changes() {
            guard !Task.isCancelled else { return }
            await refreshFavoritedThreadIDs()
        }
    }

    /// A board's 阅读方式 change remaps rows' effective categories live —
    /// without this, a page kept alive in the navigation stack would keep
    /// showing (and filtering by) the stale mapping until some history
    /// change happened to trigger a reload.
    func observeSettingsChanges() async {
        for await _ in settingsStore.changes() {
            guard !Task.isCancelled else { return }
            scheduleReload()
        }
    }

    func delete(_ entry: BrowsingHistoryEntry) async {
        guard let browsingHistoryStore else { return }
        entries.removeAll { $0.id == entry.id }
        do {
            try await browsingHistoryStore.delete(id: entry.id)
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    func clearAll() async {
        guard let browsingHistoryStore else { return }
        entries = []
        do {
            try await browsingHistoryStore.clearAll()
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    func openTarget(for entry: BrowsingHistoryEntry) async -> BrowsingHistoryOpenTarget? {
        await openTargetResolver.openTarget(for: entry)
    }

    // MARK: - Favorite heart

    /// The thread the heart reads and writes for this row (decision #11):
    /// the row's own thread, or the current chapter for a directory-level
    /// manga row.
    func heartThreadID(for entry: BrowsingHistoryEntry) -> String? {
        entry.target.threadID ?? entry.chapterThreadID
    }

    func isFavorited(_ entry: BrowsingHistoryEntry) -> Bool {
        guard let threadID = heartThreadID(for: entry) else { return false }
        return favoritedThreadIDs.contains(threadID)
    }

    func toggleFavorite(_ entry: BrowsingHistoryEntry) async {
        guard let threadID = heartThreadID(for: entry) else { return }
        let settings = await settingsStore.load().favorites
        if let item = await storedFavoriteItem(threadID: threadID) {
            let favorite = Favorite(
                id: item.id,
                title: item.title,
                displayName: item.displayName,
                threadID: threadID,
                remoteFavoriteID: item.remoteMapping?.yamiboFavoriteID,
                type: .other,
                tagIDs: item.tagIDs
            )
            let canRemoveRemote = favorite.remoteFavoriteID?.isEmpty == false
            switch FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote) {
            case .prompt:
                favoriteRemovePrompt = FavoriteRemovePrompt(favorite: favorite)
            case let .silent(removeRemote):
                await performFavoriteRemoval(favorite, removeRemote: removeRemote)
            }
            return
        }

        switch FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: true) {
        case .prompt:
            pendingFavoriteAddEntry = entry
            favoriteAddPromptPresented = true
        case let .silent(syncToRemote):
            await performFavoriteAdd(entry, syncToRemote: syncToRemote)
        }
    }

    func confirmFavoriteAdd(syncToRemote: Bool, remember: Bool) async {
        favoriteAddPromptPresented = false
        guard let entry = pendingFavoriteAddEntry else { return }
        pendingFavoriteAddEntry = nil
        if remember {
            await rememberAddSyncChoice(syncToRemote)
        }
        await performFavoriteAdd(entry, syncToRemote: syncToRemote)
    }

    func confirmFavoriteRemoval(_ favorite: Favorite, removeRemote: Bool, remember: Bool) async {
        favoriteRemovePrompt = nil
        if remember {
            await rememberRemoveRemoteChoice(removeRemote)
        }
        await performFavoriteRemoval(favorite, removeRemote: removeRemote)
    }

    /// Heart long-press: opens the location picker pre-filled with this
    /// row's current locations (empty if not yet favorited).
    func presentFavoriteLocationPicker(_ entry: BrowsingHistoryEntry) async {
        guard let threadID = heartThreadID(for: entry) else { return }
        let document = (try? await favoriteLibraryStore.load()) ?? FavoriteLibraryDocument()
        let currentLocations = document.items.first { $0.target.threadID == threadID }?.locations ?? []
        pendingFavoriteLocationEntry = entry
        favoriteLocationPickerContext = FavoriteLocationPickerContext(
            document: document,
            initialSelection: Set(currentLocations),
            isFavorited: favoritedThreadIDs.contains(threadID),
            localFavoriteLibraryStore: favoriteLibraryStore
        )
    }

    /// Routes the picker's confirmed selection: not-yet-favorited creates
    /// with those locations (still subject to the add-sync prompt); already
    /// favorited with a non-empty selection re-pins locally; already
    /// favorited with everything cleared is treated as unfavoriting, through
    /// the normal remove-sync decision — mirroring Android.
    func confirmFavoriteLocationSelection(_ locations: Set<FavoriteLocation>) async {
        favoriteLocationPickerContext = nil
        guard let entry = pendingFavoriteLocationEntry else { return }
        pendingFavoriteLocationEntry = nil
        guard let threadID = heartThreadID(for: entry) else { return }

        if let item = await storedFavoriteItem(threadID: threadID) {
            let favorite = Favorite(
                id: item.id,
                title: item.title,
                displayName: item.displayName,
                threadID: threadID,
                remoteFavoriteID: item.remoteMapping?.yamiboFavoriteID,
                type: .other,
                tagIDs: item.tagIDs
            )
            guard !locations.isEmpty else {
                let settings = await settingsStore.load().favorites
                let canRemoveRemote = favorite.remoteFavoriteID?.isEmpty == false
                switch FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote) {
                case .prompt:
                    favoriteRemovePrompt = FavoriteRemovePrompt(favorite: favorite)
                case let .silent(removeRemote):
                    await performFavoriteRemoval(favorite, removeRemote: removeRemote)
                }
                return
            }
            await performFavoriteRelocate(threadID: threadID, locations: Array(locations))
            return
        }

        guard !locations.isEmpty else { return }
        pendingFavoriteLocations = Array(locations)
        let settings = await settingsStore.load().favorites
        switch FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: true) {
        case .prompt:
            pendingFavoriteAddEntry = entry
            favoriteAddPromptPresented = true
        case let .silent(syncToRemote):
            await performFavoriteAdd(entry, syncToRemote: syncToRemote)
        }
    }

    func clearTransientMessage() {
        transientMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    private func performFavoriteAdd(_ entry: BrowsingHistoryEntry, syncToRemote: Bool) async {
        guard let threadID = heartThreadID(for: entry) else { return }
        let locations = pendingFavoriteLocations
        pendingFavoriteLocations = nil
        do {
            let result = try await FavoriteQuickActions.addFavorite(
                threadID: threadID,
                title: favoriteTitle(for: entry),
                type: .other,
                authorID: entry.authorID,
                forumID: entry.forumID,
                localTargetKindOverride: favoriteTargetKind(for: entry),
                locations: locations,
                formHash: nil,
                syncToRemote: syncToRemote,
                boardReaderSettings: await settingsStore.load().boardReader,
                localFavoriteLibraryStore: favoriteLibraryStore,
                remoteRepository: await makeFavoriteRepository()
            )
            favoritedThreadIDs.insert(threadID)
            transientMessage = result.remote.addFeedbackMessage
        } catch {
            errorMessage = error.localizedDescription
            await refreshFavoritedThreadIDs()
        }
    }

    private func performFavoriteRelocate(threadID: String, locations: [FavoriteLocation]) async {
        do {
            try await FavoriteQuickActions.relocateFavorite(
                threadID: threadID,
                locations: locations,
                localFavoriteLibraryStore: favoriteLibraryStore
            )
            transientMessage = L10n.string("favorites.quick.relocated")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performFavoriteRemoval(_ favorite: Favorite, removeRemote: Bool) async {
        do {
            try await FavoriteQuickActions.removeFavorite(
                favorite,
                removeRemote: removeRemote,
                boardReaderSettings: await settingsStore.load().boardReader,
                localFavoriteLibraryStore: favoriteLibraryStore,
                remoteRepository: removeRemote ? await makeFavoriteRepository() : nil
            )
            favoritedThreadIDs.remove(favorite.threadID)
            transientMessage = removeRemote
                ? L10n.string("favorites.quick.removed_with_remote")
                : L10n.string("favorites.quick.removed")
        } catch {
            errorMessage = error.localizedDescription
            await refreshFavoritedThreadIDs()
        }
    }

    /// A directory-level row favorites its *current chapter* (decision #11),
    /// so the stored favorite title carries the chapter alongside the work
    /// name — the row itself only knows the work title, not the chapter
    /// thread's real forum title.
    private func favoriteTitle(for entry: BrowsingHistoryEntry) -> String {
        if entry.target.kind == .mangaTitle, let chapterTitle = entry.chapterTitle,
           !chapterTitle.isEmpty, chapterTitle != entry.title {
            return "\(entry.title) \(chapterTitle)"
        }
        return entry.title
    }

    /// History rows already know their content's form — no fid-based
    /// re-classification (a manga row's board may not even be recorded).
    /// The heart stamps the row's *effective* category (the same one the row
    /// displays under and opens with, R13) — hearting a pre-configuration
    /// normal row on a now-小说 board must produce the same `.novelThread`
    /// favorite that starring the thread on the board page would. Rows whose
    /// board has no entry keep their recorded identity, exactly like the
    /// display/open dispatch.
    private func favoriteTargetKind(for entry: BrowsingHistoryEntry) -> FavoriteItemTargetKind {
        effectiveCategory(for: entry).favoriteTargetKind
    }

    private func storedFavoriteItem(threadID: String) async -> FavoriteItem? {
        (try? await favoriteLibraryStore.load())?.items.first { $0.target.threadID == threadID }
    }

    private func refreshFavoritedThreadIDs() async {
        let document = try? await favoriteLibraryStore.load()
        favoritedThreadIDs = Set((document?.items ?? []).compactMap { $0.target.threadID })
    }

    private func refreshCovers(for entries: [BrowsingHistoryEntry], generation: Int) async {
        var keysByEntryID: [String: ContentCoverKey] = [:]
        for entry in entries {
            if let key = ContentCoverKey(target: entry.target) {
                keysByEntryID[entry.id] = key
            }
        }
        let coversByKey = await contentCoverStore.covers(for: Array(keysByEntryID.values))
        guard generation == reloadGeneration else { return }
        var covers: [String: URL] = [:]
        for (entryID, key) in keysByEntryID {
            if let url = coversByKey[key]?.resolvedURL {
                covers[entryID] = url
            }
        }
        coverURLsByEntryID = covers
    }

    private func rememberAddSyncChoice(_ syncToRemote: Bool) async {
        await FavoriteQuickActions.rememberAddSyncChoice(syncToRemote, settingsStore: settingsStore)
    }

    private func rememberRemoveRemoteChoice(_ removeRemote: Bool) async {
        await FavoriteQuickActions.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore)
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

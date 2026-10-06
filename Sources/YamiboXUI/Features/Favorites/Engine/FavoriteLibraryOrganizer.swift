import Foundation
import Observation
import YamiboXCore

enum LocalFavoriteDeleteScope: Equatable {
    case currentLocation
    case everywhere
}

/// Pending "also delete from Yamibo?" question raised by a favorites-page
/// delete-everywhere action — the same second decision the quick-action
/// remove flow models with `FavoriteRemovePrompt`, kept as its own type
/// because the subject here is an item or the whole selection, not a
/// `Favorite`.
struct LocalFavoriteRemoveRemotePrompt: Identifiable, Equatable {
    enum Subject: Equatable {
        case item(FavoriteItem)
        case selection
    }

    let subject: Subject

    var id: String {
        switch subject {
        case let .item(item):
            "item-\(item.id)"
        case .selection:
            "selection"
        }
    }
}

/// Coordinates the local favorite library document: category, collection, tag
/// and item organization, navigation state, and filter-driven derivation of
/// the rendered cards.
///
/// All document mutations funnel through `commit`, and all derived output
/// (cards, counts, visible collections) is recomputed exclusively by
/// `refreshDerivedState()` whenever an input changes.
@MainActor
@Observable
final class FavoriteLibraryOrganizer {
    private(set) var document = FavoriteLibraryDocument() {
        didSet {
            unreadItemsRevision &+= 1
            cachedTagAssociationCounts = nil
            cachedSourceFilterLabels = nil
            refreshDerivedState()
        }
    }
    /// Tracks assignments and nested value mutations, including same-count replacements.
    private(set) var unreadItemsRevision: UInt64 = 0
    var selectedCategoryID = FavoriteCategory.defaultID {
        didSet {
            selection.clearSelection()
            if let selectedCollectionID,
               !document.collections.contains(where: { $0.id == selectedCollectionID && $0.categoryID == selectedCategoryID }) {
                self.selectedCollectionID = nil
            }
            refreshDerivedState()
            persistNavigationState()
        }
    }
    var selectedCollectionID: String? {
        didSet {
            selection.clearSelection()
            refreshDerivedState()
            persistNavigationState()
        }
    }
    /// The open archive's stable directory ID, or a transient display-group
    /// key while its original member threads have not resolved together.
    /// Mirrors `selectedCollectionID`'s own navigation-state shape but is
    /// deliberately not persisted through `SettingsStore` (see
    /// `persistNavigationState()`): this scope is a live identity, not
    /// durable navigation state worth restoring across launches.
    private(set) var selectedMergedGroupKey: String? = nil
    /// Only a transient, unresolved archive needs chapter anchors. Keep its
    /// original members visible until all surviving members resolve together.
    private var unresolvedMergedGroupThreadIDs: Set<String>?
    var filter = LocalFavoriteFilterState() {
        didSet {
            guard filter != oldValue else { return }
            refreshDerivedState()
        }
    }
    private(set) var derived = LocalFavoriteDerivedState()
    /// `derived` scoped as if no collection were open, regardless of
    /// `selectedCollectionID`. The root favorites screen renders from this
    /// (never from `derived`) because `NavigationStack` keeps the root view
    /// mounted underneath a pushed collection detail page, and its stock
    /// interactive edge-swipe-back gesture reveals that root view mid-drag
    /// while `selectedCollectionID` is still set — reading the same
    /// collection-scoped `derived` there would show the collection page
    /// duplicated behind itself. See `LocalFavoritesOrganizationView`.
    private(set) var rootDerived = LocalFavoriteDerivedState()
    private(set) var display = FavoriteLibraryDisplayState()
    /// Snapshot of `settings.favorites.smartMangaBadgeEnabled`, kept live
    /// alongside `smartMangaBulkDeleteEnabled` (see `settingsUpdatesTask`) —
    /// but observable rather than `@ObservationIgnored`, because the card
    /// views read it in `body` to show or hide the sparkles badge and must
    /// re-render when the Settings switch flips.
    private(set) var smartMangaBadgeEnabled = true
    private(set) var removeRemotePromptEnabled = true
    private(set) var removeRemoteDefault = false
    var backgroundSettings: FavoriteBackgroundSettings { background.settings }
    var backgroundImageData: Data? { background.imageData }
    private let background: CustomBackgroundState
    @ObservationIgnored let covers: FavoriteCoverCoordinator
    var coverLookup: FavoriteCoverCoordinator.Lookup { covers.lookup }

    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    var errorDetails: LoadFailureDetails?
    /// Short-lived toast feedback (single-item sync results and similar).
    var transientFeedback: TransientFeedback?
    var transientMessage: String? {
        get { transientFeedback?.message }
        set { transientFeedback = newValue.map { TransientFeedback(message: $0) } }
    }
    /// Non-nil while a delete-everywhere action waits for the user's "also
    /// delete from Yamibo?" answer (`removeRemotePromptEnabled`). The view
    /// renders it as a confirmation dialog; both confirm variants route back
    /// through `confirmRemoveRemotePrompt`, dismissal aborts the delete.
    var removeRemotePrompt: LocalFavoriteRemoveRemotePrompt?

    /// Selection and search-mode session shared with the views.
    let selection = LocalFavoriteBrowseSession()

    private let libraryStore: FavoriteLibraryStore
    private let readingProgressStore: ReadingProgressStore
    let settingsStore: SettingsStore
    let mangaDirectoryStore: (any MangaDirectoryReading & MangaDirectoryChangeObserving)?
    private let makeFavoriteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating

    @ObservationIgnored private var readingProgress: [ReadingProgressRecord] = []
    @ObservationIgnored private let derivationWorker = FavoriteLibraryDerivationWorker()
    @ObservationIgnored private var derivationTask: Task<Void, Never>?
    @ObservationIgnored private var derivationGeneration: UInt64 = 0
    /// tid → resolved `MangaDirectory`, for virtual favorites grouping
    /// (smart-comic-mode decision #3/#5). Populated only at `load()`/
    /// `reload()` via one batched `MangaDirectoryBatchReading.directories
    /// (containingTIDs:)` call — never recomputed per render (the design
    /// doc's performance constraint #2).
    @ObservationIgnored var mangaDirectoriesByTID: [String: MangaDirectory] = [:] {
        didSet { mangaDirectoriesRevision &+= 1 }
    }
    private(set) var mangaDirectoriesRevision: UInt64 = 0
    /// Includes mode-off members so changing presentation never hides an existing update.
    var unreadMangaDirectoriesByTID: [String: MangaDirectory] = [:] {
        didSet { unreadDirectoriesRevision &+= 1 }
    }
    private(set) var unreadDirectoriesRevision: UInt64 = 0
    /// Snapshot of the per-board reader configuration taken at the same
    /// load/reload as `mangaDirectoriesByTID`, so the two are always
    /// consistent with each other for a given derivation.
    var boardReaderSettings = BoardReaderSettings() {
        didSet { cachedSourceFilterLabels = nil }
    }
    @ObservationIgnored private var cachedSourceFilterLabels: FavoriteSourceFilterLabels?

    private struct SelectionLocationCacheKey: Equatable {
        let documentRevision: UInt64
        let directoriesRevision: UInt64
        let boardReaderSettings: BoardReaderSettings
        let memberScopeGroupKey: String?
        let selectedFavoriteIDs: Set<String>
    }
    @ObservationIgnored private var cachedSelectionLocations: (
        key: SelectionLocationCacheKey, snapshot: LocalFavoriteLocationMembershipSnapshot
    )?

    /// Presentation cache only. Commands still expand the current selection
    /// independently and commit against the latest persisted document.
    var selectionLocationSnapshot: LocalFavoriteLocationMembershipSnapshot {
        // Read observable revisions even on a cache hit. Directory metadata
        // is otherwise observation-ignored, and a same-count replacement of
        // items or directories must still invalidate the displayed states.
        let key = SelectionLocationCacheKey(
            documentRevision: unreadItemsRevision,
            directoriesRevision: mangaDirectoriesRevision,
            boardReaderSettings: boardReaderSettings,
            memberScopeGroupKey: selectedMergedGroupKey,
            selectedFavoriteIDs: selection.selectedFavoriteIDs
        )
        if let cachedSelectionLocations, cachedSelectionLocations.key == key {
            return cachedSelectionLocations.snapshot
        }
        let ids = expandedSelectionFavoriteIDs(key.selectedFavoriteIDs)
        let snapshot = LocalFavoriteLocationMembershipSnapshot(
            items: document.items.filter { ids.contains($0.id) },
            displayedItemCount: ids.count
        )
        cachedSelectionLocations = (key, snapshot)
        return snapshot
    }

    private var sourceFilterLabels: FavoriteSourceFilterLabels {
        let items = document.items // Keep the observable document dependency on warm reads.
        if let cachedSourceFilterLabels { return cachedSourceFilterLabels }
        let labels = FavoriteSourceFilterLabels(items: items)
        cachedSourceFilterLabels = labels
        return labels
    }

    func sourceFilterLabel(_ filter: LocalFavoriteSourceFilter) -> String {
        guard case .forumBoard = filter else { return filter.displayLabel }
        return sourceFilterLabels.label(for: filter, boardReaderSettings: boardReaderSettings)
    }

    func sortedSourceFilters<S: Sequence>(_ filters: S) -> [LocalFavoriteSourceFilter]
    where S.Element == LocalFavoriteSourceFilter {
        filters.map { (filter: $0, label: sourceFilterLabel($0)) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            .map(\.filter)
    }
    /// Snapshot of `settings.favorites.smartMangaBulkDeleteEnabled`, kept
    /// live alongside `boardReaderSettings` (see `settingsUpdatesTask`) so
    /// `hasDeletableSelection` and `LocalFavoriteCardActions.standard(...)`
    /// — both synchronous reads — see a change made from Settings without
    /// waiting for an unrelated reload.
    @ObservationIgnored private(set) var smartMangaBulkDeleteEnabled = true
    @ObservationIgnored private var libraryUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var progressUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var progressObservationGeneration: UInt64 = 0
    @ObservationIgnored private var settingsUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var mangaDirectoryUpdatesTask: Task<Void, Never>?

    init(
        libraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        favoriteBackgroundImageStore: FavoriteBackgroundImageStore,
        mangaDirectoryStore: (any MangaDirectoryReading & MangaDirectoryChangeObserving)? = nil,
        makeForumThreadReaderRepository: (@Sendable () async -> any ThreadCoverPageResolving)? = nil,
        makeFavoriteRepository: @escaping @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    ) {
        self.libraryStore = libraryStore
        self.readingProgressStore = readingProgressStore
        self.settingsStore = settingsStore
        self.background = CustomBackgroundState(settingsStore: settingsStore, imageStore: favoriteBackgroundImageStore, scope: .favorites)
        self.covers = FavoriteCoverCoordinator(
            store: contentCoverStore,
            makeRepository: makeForumThreadReaderRepository
        )
        self.mangaDirectoryStore = mangaDirectoryStore
        self.makeFavoriteRepository = makeFavoriteRepository
        covers.onChange = { [weak self] in self?.refreshDerivedState() }
        libraryUpdatesTask = StoreChangeObservation.task(
            changes: { [store = libraryStore] in store.changes() },
            changeID: { [store = libraryStore] in store.changeID }
        ) { [weak self] in
            await self?.reload()
        }
        observeReadingProgressIfNeeded()
        // Without this, toggling the new Smart Comic Mode settings UI while
        // the Favorites tab is already loaded would leave the merged-card
        // grouping stale until some unrelated favorite/progress/cover change
        // happened to trigger a reload — the settings VALUE was always
        // modeled/consumed correctly, but nothing here reacted to it
        // changing live.
        settingsUpdatesTask = StoreChangeObservation.task(
            changes: { [store = settingsStore] in store.changes() },
            changeID: { [store = settingsStore] in store.changeID }
        ) { [weak self] in
            await self?.reloadBoardReaderSettings()
            await self?.reloadFavoriteSettingsSnapshots()
        }
        // Without this, renaming a manga directory from the manga reader's
        // directory page would leave an already-open Favorites tab showing
        // the old name/cover on a merged card until some unrelated
        // favorite/progress/cover/settings change happened to trigger a
        // full reload.
        if let mangaDirectoryStore {
            mangaDirectoryUpdatesTask = StoreChangeObservation.task(
                changes: { [store = mangaDirectoryStore] in store.changes() },
                changeID: { [store = mangaDirectoryStore] in store.changeID }
            ) { [weak self] in
                await self?.reloadMangaDirectories()
            }
        }
    }

    deinit {
        derivationTask?.cancel()
        libraryUpdatesTask?.cancel()
        progressUpdatesTask?.cancel()
        settingsUpdatesTask?.cancel()
        mangaDirectoryUpdatesTask?.cancel()
    }

    // MARK: - Document access

    var categories: [FavoriteCategory] {
        document.categories
    }

    var collections: [LocalFavoriteCollection] {
        document.collections
    }

    var tags: [FavoriteTag] {
        document.tags.sorted { lhs, rhs in
            if lhs.manualOrder != rhs.manualOrder {
                return lhs.manualOrder < rhs.manualOrder
            }
            return lhs.id < rhs.id
        }
    }

    /// Current items also feed the root's visible-cover prefetch snapshot.
    var favoriteItems: [FavoriteItem] { document.items }

    @ObservationIgnored private var cachedTagAssociationCounts: [String: Int]?

    /// Selection and search do not change associations. Reuse the counts
    /// until the organizer receives another document, including after sync.
    var favoriteTagAssociationCounts: [String: Int] {
        let items = document.items // Keep the observable document dependency.
        if let cachedTagAssociationCounts { return cachedTagAssociationCounts }
        let counts = tagAssociationCounts(from: items)
        cachedTagAssociationCounts = counts
        return counts
    }

    var currentCategoryCollections: [LocalFavoriteCollection] {
        document.collections
            .filter { $0.categoryID == selectedCategoryID }
            .sorted { lhs, rhs in
                if lhs.manualOrder != rhs.manualOrder {
                    return lhs.manualOrder < rhs.manualOrder
                }
                return lhs.id < rhs.id
            }
    }

    var selectedCollection: LocalFavoriteCollection? {
        guard let selectedCollectionID else { return nil }
        return document.collections.first { $0.id == selectedCollectionID }
    }

    var singleSelectedCollection: LocalFavoriteCollection? {
        guard selection.selectedCollectionIDs.count == 1,
              let id = selection.selectedCollectionIDs.first else { return nil }
        return document.collections.first { $0.id == id }
    }

    /// Whether the currently selected favorites can be removed from just this
    /// category or collection (they all remain reachable elsewhere).
    var selectedFavoritesCanRemoveCurrentLocation: Bool {
        guard selection.selectedCollectionCount == 0 else { return false }
        return derived.cards.contains { card in
            selection.selectedFavoriteIDs.contains(card.id) && card.item.locations.count > 1
        }
    }

    /// Tag IDs shared by every selected favorite; seed for bulk tag editing.
    var commonTagIDsForSelection: Set<String> {
        let selectedIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let selectedItems = document.items.filter { selectedIDs.contains($0.id) }
        guard let first = selectedItems.first else { return [] }
        return selectedItems.dropFirst().reduce(Set(first.tagIDs)) { partialResult, item in
            partialResult.intersection(Set(item.tagIDs))
        }
    }

    // MARK: - Loading

    func load() async {
        observeReadingProgressIfNeeded()
        let loadedDocument: FavoriteLibraryDocument
        do {
            loadedDocument = try await libraryStore.load()
        } catch {
            // Keep whatever the UI currently shows; an empty placeholder here
            // would read as "all favorites gone".
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return
        }
        let settings = await settingsStore.load()
        boardReaderSettings = settings.boardReader
        smartMangaBulkDeleteEnabled = settings.favorites.smartMangaBulkDeleteEnabled
        smartMangaBadgeEnabled = settings.favorites.smartMangaBadgeEnabled
        removeRemotePromptEnabled = settings.favorites.removeRemotePromptEnabled
        removeRemoteDefault = settings.favorites.removeRemoteDefault
        mangaDirectoriesByTID = await resolveMangaDirectories(for: loadedDocument.items, boardReaderSettings: boardReaderSettings)
        await covers.refresh(.init(items: loadedDocument.items, directories: Array(Set(mangaDirectoriesByTID.values))))
        display = FavoriteLibraryDisplayState(
            layoutMode: settings.favorites.layoutMode,
            showsCategoryCounts: settings.favorites.showsCategoryCounts,
            gridCardScale: FavoriteLibrarySettings.clampGridCardScale(settings.favorites.gridCardScale)
        )
        await background.reload()
        withCoalescedDerivedRefresh {
            var restoredFilter = filter
            restoredFilter.sortOrder = settings.favorites.sortOrder
            restoredFilter.sortDescending = settings.favorites.sortDescending
            filter = restoredFilter
            document = loadedDocument
            let savedCollection = settings.favorites.selectedCollectionID.flatMap { savedID in
                loadedDocument.collections.first { $0.id == savedID }
            }
            if let savedCollection {
                selectedCategoryID = savedCollection.categoryID
            } else if let savedCategoryID = settings.favorites.selectedCategoryID,
                      loadedDocument.categories.contains(where: { $0.id == savedCategoryID }) {
                selectedCategoryID = savedCategoryID
            }
            if !loadedDocument.categories.contains(where: { $0.id == selectedCategoryID }) {
                selectedCategoryID = loadedDocument.defaultCategory.id
            }
            if let savedCollection, savedCollection.categoryID == selectedCategoryID {
                selectedCollectionID = savedCollection.id
            } else {
                selectedCollectionID = nil
            }
        }
        scheduleMangaCoverBackfill(for: loadedDocument.items)
        await derivationTask?.value
    }

    func reload() async {
        guard let loadedDocument = try? await libraryStore.load() else {
            // Transient read failure: keep the current document on screen and
            // let the next change notification retry.
            return
        }
        // Only the Smart Comic Mode snapshot is refreshed here — unlike
        // `load()`, `reload()` deliberately never re-applies
        // `settings.favorites` (sort order/layout/etc.) so a background
        // reload triggered by an unrelated favorite/progress/cover change
        // can't clobber the sort order the user may have just changed live
        // in this session.
        let settings = await settingsStore.load()
        boardReaderSettings = settings.boardReader
        mangaDirectoriesByTID = await resolveMangaDirectories(for: loadedDocument.items, boardReaderSettings: boardReaderSettings)
        await covers.refresh(.init(items: loadedDocument.items, directories: Array(Set(mangaDirectoriesByTID.values))))
        withCoalescedDerivedRefresh {
            document = loadedDocument
            if !loadedDocument.categories.contains(where: { $0.id == selectedCategoryID }) {
                selectedCategoryID = loadedDocument.defaultCategory.id
            }
            if let selectedCollectionID,
               !loadedDocument.collections.contains(where: { $0.id == selectedCollectionID && $0.categoryID == selectedCategoryID }) {
                self.selectedCollectionID = nil
            }
            // Tags removed by another device (WebDAV) must not linger as an
            // invisible active filter.
            let validTagIDs = Set(loadedDocument.tags.map(\.id))
            if !filter.selectedTagIDs.isSubset(of: validTagIDs) {
                filter.selectedTagIDs.formIntersection(validTagIDs)
            }
        }
        scheduleMangaCoverBackfill(for: loadedDocument.items)
    }

    private func observeReadingProgressIfNeeded() {
        guard !isBookPresentationActive, progressUpdatesTask == nil else { return }
        progressObservationGeneration &+= 1
        let generation = progressObservationGeneration
        progressUpdatesTask = Task { @MainActor [weak self, store = readingProgressStore] in
            guard !Task.isCancelled else { return }
            let snapshots = await store.snapshots()
            guard !Task.isCancelled else { return }
            do {
                for try await snapshot in snapshots {
                    guard !Task.isCancelled, let self,
                          self.progressObservationGeneration == generation else { return }
                    self.applyReadingProgress(snapshot)
                }
            } catch {
                if !Task.isCancelled, let self,
                   self.progressObservationGeneration == generation,
                   !LoadDiagnosticError.isCancellation(error) {
                    // Keep the last valid snapshot on failure. A later load
                    // can subscribe again instead of showing empty progress.
                    self.errorMessage = error.localizedDescription
                    self.errorDetails = LoadFailureDetails(error: error)
                }
            }
            guard !Task.isCancelled, let self,
                  self.progressObservationGeneration == generation else { return }
            self.progressUpdatesTask = nil
        }
    }

    private func applyReadingProgress(_ snapshot: [ReadingProgressRecord]) {
        guard readingProgress != snapshot else { return }
        readingProgress = snapshot
        refreshDerivedState()
    }

    /// Re-derives only the Smart Comic Mode-dependent slice of state
    /// (`boardReaderSettings`/`mangaDirectoriesByTID`/`coverLookup`'s
    /// `.smartManga` slice) in response to *any*
    /// `SettingsStore.changes()` element — mirroring `reload()`'s
    /// deliberately narrower approach (see the comment at `reload()`):
    /// this must never re-apply `settings.favorites` (sort order/layout/
    /// selected category/collection), or an unrelated settings save made
    /// elsewhere (including this organizer's own `persistViewPreferences`/
    /// `persistNavigationState`) would clobber sort/filter state the user
    /// may have just changed live in this session. Guarded on an actual
    /// diff so unrelated settings saves (which also post this notification)
    /// don't re-run the manga-directory batch query for no reason.
    private func reloadBoardReaderSettings() async {
        let settings = await settingsStore.load()
        guard settings.boardReader != boardReaderSettings else { return }
        boardReaderSettings = settings.boardReader
        mangaDirectoriesByTID = await resolveMangaDirectories(for: document.items, boardReaderSettings: boardReaderSettings)
        await covers.refreshSmartManga(Array(Set(mangaDirectoriesByTID.values)))
        refreshDerivedState()
        scheduleMangaCoverBackfill(for: document.items)
    }

    /// Refreshes the favorites settings read synchronously by the browse view
    /// after Settings changes, so its menu, badge, and delete confirmation
    /// reflect the latest preferences without waiting for an unrelated reload.
    private func reloadFavoriteSettingsSnapshots() async {
        let settings = await settingsStore.load()
        removeRemotePromptEnabled = settings.favorites.removeRemotePromptEnabled
        removeRemoteDefault = settings.favorites.removeRemoteDefault
        if settings.favorites.smartMangaBulkDeleteEnabled != smartMangaBulkDeleteEnabled {
            smartMangaBulkDeleteEnabled = settings.favorites.smartMangaBulkDeleteEnabled
        }
        if settings.favorites.smartMangaBadgeEnabled != smartMangaBadgeEnabled {
            smartMangaBadgeEnabled = settings.favorites.smartMangaBadgeEnabled
        }
    }

    /// Re-derives the manga-directory-dependent slice of state
    /// (`mangaDirectoriesByTID`/`coverLookup`'s `.smartManga` slice) in
    /// response to `MangaDirectoryChangeObserving.changes()` -- e.g.
    /// resolving a previously-unresolved manga favorite's directory for the
    /// first time (`saveDirectory`), or renaming a directory from the manga
    /// reader's directory page (`renameDirectory`). Without this, a newly-
    /// resolved directory's merge/cover (or a rename's effect on a merged
    /// card's displayed `cleanBookName`/`.smartManga` cover) would stay stale
    /// in an already-open Favorites tab until some unrelated
    /// favorite/progress/cover/settings change happened to trigger a
    /// full reload.
    ///
    /// Reading progress follows its own database snapshot observation, which
    /// also sees the directory identity transaction. Do not issue a second
    /// progress query here or let a late manual read overwrite a newer snapshot.
    private func reloadMangaDirectories() async {
        if let store = mangaDirectoryStore {
            if let key = selectedMergedGroupKey,
               let directory = try? await store.directory(id: MangaDirectoryID(rawValue: key)),
               directory.id.rawValue != key {
                selectedMergedGroupKey = directory.id.rawValue
            }
            var normalizedSelection = selection.selectedFavoriteIDs
            for key in selection.selectedFavoriteIDs {
                if let directory = try? await store.directory(id: MangaDirectoryID(rawValue: key)),
                   directory.id.rawValue != key {
                    normalizedSelection.remove(key)
                    normalizedSelection.insert(directory.id.rawValue)
                }
            }
            selection.replaceFavoriteSelection(with: normalizedSelection)
        }
        mangaDirectoriesByTID = await resolveMangaDirectories(for: document.items, boardReaderSettings: boardReaderSettings)
        await covers.refreshSmartManga(Array(Set(mangaDirectoriesByTID.values)))
        refreshDerivedState()
    }

    // MARK: - Categories

    /// Pushes one favorite item to Yamibo (card context menu action).
    func pushItemToYamibo(_ item: FavoriteItem) async {
        do {
            let repository = await makeFavoriteRepository()
            let result = try await FavoriteCommands.pushFavoriteItemToYamibo(
                item,
                localFavoriteLibraryStore: libraryStore,
                remoteRepository: repository
            )
            switch result {
            case .synced:
                transientMessage = L10n.string("favorites.quick.sync_item.synced")
            case .syncedWithoutMapping:
                transientMessage = L10n.string("favorites.quick.sync_item.pending")
            case .notAttempted, .failed:
                break
            }
        } catch {
            YamiboLog.sync.error("Failed to sync favorite item \(item.id) to Yamibo: \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    @discardableResult
    func createCategory(name: String) async -> FavoriteCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let category = await commit { document in
            document.createCategory(name: trimmed)
        }
        if let category {
            selectedCategoryID = category.id
        }
        return category
    }

    func renameCategory(id: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await commit { document in
            document.renameCategory(id: id, name: trimmed)
        }
    }

    func deleteCategory(id: String) async {
        await commit { document in
            document.deleteCategory(id: id)
        }
        if !document.categories.contains(where: { $0.id == selectedCategoryID }) {
            selectedCategoryID = document.defaultCategory.id
        }
    }

    func moveCategory(id: String, direction: CategoryMoveDirection) async {
        guard let orderedIDs = document.reorderedCategoryIDs(moving: id, direction) else { return }
        await commit { document in
            document.reorderCategories(orderedIDs: orderedIDs)
        }
    }

    func reorderCategories(_ orderedIDs: [String]) async {
        await commit { document in
            document.reorderCategories(orderedIDs: orderedIDs)
        }
    }

    // MARK: - Collections

    func openCollection(id: String) {
        guard let collection = document.collections.first(where: { $0.id == id }) else { return }
        if selectedCategoryID != collection.categoryID {
            selectedCategoryID = collection.categoryID
        }
        selectedCollectionID = id
    }

    func closeCollection() {
        selectedCollectionID = nil
    }

    @discardableResult
    func createCollection(name: String, color: FavoriteCollectionColor = .gray) async -> LocalFavoriteCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryID = selectedCategoryID
        guard !trimmed.isEmpty else { return nil }
        let collection = await commit { document in
            document.createCollection(categoryID: categoryID, name: trimmed, color: color)
        }
        if let collection {
            selectedCollectionID = collection.id
        }
        return collection
    }

    func updateCollection(id: String, name: String, color: FavoriteCollectionColor) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await commit { document in
            document.renameCollection(id: id, name: trimmed)
            document.recolorCollection(id: id, color: color)
        }
    }

    func dissolveCollection(id: String) async {
        let committed: Void? = await commit { document in
            document.dissolveCollection(id: id)
        }
        guard committed != nil else { return }
        if selectedCollectionID == id {
            selectedCollectionID = nil
        }
    }

    func moveCollection(id: String, direction: CategoryMoveDirection) async {
        guard let reorder = document.reorderedCollectionIDs(moving: id, direction) else { return }
        await commit { document in
            document.reorderCollections(categoryID: reorder.categoryID, orderedIDs: reorder.orderedIDs)
        }
    }

    func moveCollection(id: String, toCategoryID categoryID: String) async {
        let committed: Void? = await commit { document in
            document.moveCollection(id: id, toCategoryID: categoryID)
        }
        guard committed != nil else { return }
        if selectedCollectionID == id {
            selectedCategoryID = categoryID
        }
    }

    // MARK: - Merged smart-comic groups

    /// Opens a smart card's "查看归档收藏" detail page, scoping `derived.cards`
    /// (not `rootDerived`) to every individual favorite whose own effective
    /// title (`FavoriteCardProjection.resolvedTitle`) currently matches
    /// `cleanBookName` — one item for a still-solitary smart card, 2+ for an
    /// actually merged one. Mirrors `openCollection(id:)` exactly.
    var selectedMergedGroupTitle: String? {
        guard let key = selectedMergedGroupKey else { return nil }
        return mangaDirectoriesByTID.values.first(where: { $0.id.rawValue == key })?.cleanBookName
            ?? (key.hasPrefix("unresolved-title:") ? String(key.dropFirst("unresolved-title:".count)) : nil)
    }

    func openMergedGroup(key: String) {
        unresolvedMergedGroupThreadIDs = key.hasPrefix("unresolved-title:")
            ? Set(LocalFavoriteLibraryProjection.mangaThreadItemsByGroupKey(
                in: document.items,
                mangaDirectoriesByTID: mangaDirectoriesByTID,
                boardReaderSettings: boardReaderSettings
            )[key, default: []].compactMap { $0.target.threadID })
            : nil
        selectedMergedGroupKey = key
        selection.clearSelection()
        refreshDerivedState()
    }

    /// Mirrors `closeCollection()` exactly.
    func closeMergedGroup() {
        selectedMergedGroupKey = nil
        unresolvedMergedGroupThreadIDs = nil
        selection.clearSelection()
        refreshDerivedState()
    }

    private func resolveUnresolvedMergedGroupScope() {
        guard var threadIDs = unresolvedMergedGroupThreadIDs, let key = selectedMergedGroupKey else { return }
        // Keep the unresolved page live for newly favorited chapters, while
        // retaining its previous members after their display grouping changes.
        let currentMembers = LocalFavoriteLibraryProjection.mangaThreadItemsByGroupKey(
            in: document.items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )[key, default: []]
        threadIDs.formUnion(currentMembers.compactMap { $0.target.threadID })
        unresolvedMergedGroupThreadIDs = threadIDs
        let survivingMembers = document.items.filter {
            $0.target.kind == .mangaThread && threadIDs.contains($0.target.threadID ?? "") &&
                boardReaderSettings.isSmartComicModeEnabled(forumID: $0.forumID)
        }
        guard !survivingMembers.isEmpty else { return }
        let directories = survivingMembers.compactMap { mangaDirectoriesByTID[$0.target.threadID ?? ""] }
        let ids = Set(directories.map(\.id))
        // A guessed title can cover several real works. Neither partially
        // resolved members nor conflicting IDs justify selecting one of them.
        guard directories.count == survivingMembers.count, ids.count == 1, let id = ids.first else { return }
        selectedMergedGroupKey = id.rawValue
        unresolvedMergedGroupThreadIDs = nil
    }

    // MARK: - Tags

    @discardableResult
    func createTag(name: String, color: FavoriteTagColor = .gray) async -> FavoriteTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await commit { document in
            document.createTag(name: trimmed, color: color)
        }
    }

    func updateTag(id tagID: String, name: String, color: FavoriteTagColor) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await commit { document in
            document.renameTag(id: tagID, name: trimmed)
            document.recolorTag(id: tagID, color: color)
        }
    }

    func deleteTag(id tagID: String) async {
        let committed: Void? = await commit { document in
            document.deleteTag(id: tagID)
        }
        guard committed != nil else { return }
        filter.selectedTagIDs.remove(tagID)
    }

    /// Reachable from a card's context-menu "标签" button, including a smart
    /// card's — that button is not gated on `isModeOnMangaThread` (see
    /// `LocalFavoriteCardContextMenu`), so `itemID` can be a smart card's
    /// representative item id. Routed through `expandedSelectionFavoriteIDs`
    /// so editing a smart card's tags from this single-item path applies to
    /// every favorite archived under it, exactly like `updateTagsForSelection`
    /// does for a bulk selection.
    func updateTags(for itemID: String, tagIDs: Set<String>) async {
        let expandedIDs = expandedSelectionFavoriteIDs([itemID])
        await commit { document in
            document.replaceTags(for: expandedIDs, with: tagIDs)
        }
    }

    func updateTagsForSelection(_ tagIDs: Set<String>) async {
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        guard !favoriteIDs.isEmpty else { return }
        let committed: Void? = await commit { document in
            document.replaceTags(for: favoriteIDs, with: tagIDs)
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    func reorderTags(_ orderedIDs: [String]) async {
        await commit { document in
            document.reorderTags(orderedIDs: orderedIDs)
        }
    }

    // MARK: - Items

    func deleteItem(_ item: FavoriteItem, scope: LocalFavoriteDeleteScope, removeRemote: Bool) async {
        do {
            guard let updatedDocument = try await FavoriteCommands.deleteFavorite(
                id: item.id,
                scope: deletionScope(scope, removeRemote: removeRemote),
                localFavoriteLibraryStore: libraryStore,
                makeRemoteRepository: makeFavoriteRepository
            ) else { return }
            document = updatedDocument
            errorMessage = nil
        } catch {
            presentCommitFailure(error)
        }
    }

    func deleteFavorites(_ request: FavoriteDeletionRequest) async -> Bool {
        do {
            document = try await FavoriteCommands.deleteFavorites(
                request,
                localFavoriteLibraryStore: libraryStore,
                makeRemoteRepository: makeFavoriteRepository
            )
            errorMessage = nil
            return true
        } catch {
            presentCommitFailure(error)
            return false
        }
    }

    func deletionScope(_ scope: LocalFavoriteDeleteScope, removeRemote: Bool) -> FavoriteDeletionRequest.Scope {
        switch scope {
        case .currentLocation: .currentLocation(selectionSourceLocation)
        case .everywhere: .everywhere(removeRemote: removeRemote)
        }
    }

    // MARK: - Display and sort preferences

    func updateLayoutMode(_ value: FavoriteLibraryLayoutMode) {
        guard value != display.layoutMode else { return }
        let previous = display.layoutMode
        display.layoutMode = value
        persistViewPreferences(mutate: { $0.favorites.layoutMode = value }) {
            if self.display.layoutMode == value {
                self.display.layoutMode = previous
            }
        }
    }

    /// Commits a grid card scale (pinch end on the favorites page). Values
    /// are clamped here so gesture math never persists an out-of-range or
    /// non-finite multiplier.
    func updateGridCardScale(_ value: Double) {
        let clamped = FavoriteLibrarySettings.clampGridCardScale(value)
        guard clamped != display.gridCardScale else { return }
        let previous = display.gridCardScale
        display.gridCardScale = clamped
        persistViewPreferences(mutate: { $0.favorites.gridCardScale = clamped }) {
            if self.display.gridCardScale == clamped {
                self.display.gridCardScale = previous
            }
        }
    }

    func updateShowsCategoryCounts(_ value: Bool) {
        guard value != display.showsCategoryCounts else { return }
        let previous = display.showsCategoryCounts
        display.showsCategoryCounts = value
        persistViewPreferences(mutate: { $0.favorites.showsCategoryCounts = value }) {
            if self.display.showsCategoryCounts == value {
                self.display.showsCategoryCounts = previous
            }
        }
    }

    func updateSortOrder(_ value: LocalFavoriteLibrarySortOrder) {
        guard value != filter.sortOrder else { return }
        let previous = filter.sortOrder
        filter.sortOrder = value
        persistViewPreferences(mutate: { $0.favorites.sortOrder = value }) {
            if self.filter.sortOrder == value {
                self.filter.sortOrder = previous
            }
        }
    }

    func updateSortDescending(_ value: Bool) {
        guard value != filter.sortDescending else { return }
        let previous = filter.sortDescending
        filter.sortDescending = value
        persistViewPreferences(mutate: { $0.favorites.sortDescending = value }) {
            if self.filter.sortDescending == value {
                self.filter.sortDescending = previous
            }
        }
    }

    // MARK: - Derivation

    /// While true, `refreshDerivedState()` records that a refresh is due
    /// instead of running it. `load()`/`reload()` assign several
    /// derivation inputs in sequence (filter, document, category,
    /// collection), each of whose `didSet` requests a refresh — without
    /// coalescing, one load runs the full-library derivation 4–6 times for
    /// one visible outcome.
    @ObservationIgnored private var isCoalescingDerivedRefresh = false
    @ObservationIgnored private var needsCoalescedDerivedRefresh = false
    @ObservationIgnored private var isBookPresentationActive = false
    @ObservationIgnored private var needsBookPresentationRefresh = false

    func setBookPresentationActive(_ active: Bool) {
        isBookPresentationActive = active
        if active {
            // No hidden full-history queries while reading. A fresh initial
            // snapshot on return also catches deletions and identity changes.
            progressObservationGeneration &+= 1
            progressUpdatesTask?.cancel()
            progressUpdatesTask = nil
        } else {
            observeReadingProgressIfNeeded()
        }
        if active, derivationTask != nil {
            derivationGeneration &+= 1
            derivationTask?.cancel()
            needsBookPresentationRefresh = true
        }
        if !active, needsBookPresentationRefresh {
            needsBookPresentationRefresh = false
            refreshDerivedState()
        }
    }

    private func withCoalescedDerivedRefresh(_ mutations: () -> Void) {
        // A nested batch folds into the outer one.
        if isCoalescingDerivedRefresh {
            mutations()
            return
        }
        isCoalescingDerivedRefresh = true
        mutations()
        isCoalescingDerivedRefresh = false
        if needsCoalescedDerivedRefresh {
            needsCoalescedDerivedRefresh = false
            refreshDerivedState()
        }
    }

    func refreshDerivedState() {
        // Reading progress can reorder/remove the source card. Keep the
        // displayed shelf intact until the reverse zoom has landed.
        guard !isBookPresentationActive else {
            needsBookPresentationRefresh = true
            return
        }
        guard !isCoalescingDerivedRefresh else {
            needsCoalescedDerivedRefresh = true
            return
        }
        resolveUnresolvedMergedGroupScope()
        let inputs = LocalFavoriteLibraryDerivation.Inputs(
                document: document,
                selectedCategoryID: selectedCategoryID,
                selectedCollectionID: selectedCollectionID,
                filter: filter,
                readingProgress: readingProgress,
                coverSourcesByKey: coverLookup.sourcesByKey,
                textCoverForcedKeys: coverLookup.forcedKeys,
                mangaDirectoriesByTID: mangaDirectoriesByTID,
                boardReaderSettings: boardReaderSettings,
                memberScopeGroupKey: selectedMergedGroupKey,
                memberScopeThreadIDs: unresolvedMergedGroupThreadIDs
            )
        // `derived` can now be scoped by an open merged group even while no
        // collection is open, so the old `selectedCollectionID == nil`
        // shortcut alone is no longer sufficient — it must also gate on
        // `selectedMergedGroupKey` (see `isBrowsingUnscopedRoot`),
        // or `rootDerived` would silently inherit the merged-group scope in
        // that case (opening a merged group's detail page directly from the
        // root, not from inside a collection) and defeat the whole point of
        // `rootDerived`.
        let rootInputs: LocalFavoriteLibraryDerivation.Inputs? = isBrowsingUnscopedRoot
            ? nil
            : LocalFavoriteLibraryDerivation.Inputs(
                    document: document,
                    selectedCategoryID: selectedCategoryID,
                    selectedCollectionID: nil,
                    filter: filter,
                    readingProgress: readingProgress,
                    coverSourcesByKey: coverLookup.sourcesByKey,
                    textCoverForcedKeys: coverLookup.forcedKeys,
                    mangaDirectoriesByTID: mangaDirectoriesByTID,
                    boardReaderSettings: boardReaderSettings
                    // `memberScopeGroupKey` intentionally omitted (nil
                    // default): `rootDerived` must never narrow to this scope.
            )
        derivationGeneration &+= 1
        let generation = derivationGeneration
        derivationTask?.cancel()
        derivationTask = Task { [weak self, derivationWorker] in
            guard let result = try? await derivationWorker.derive(inputs, rootInputs: rootInputs),
                  !Task.isCancelled, let self,
                  self.derivationGeneration == generation else { return }
            self.derived = result.0
            self.rootDerived = result.1
            self.derivationTask = nil
        }
        selection.prune(
            validFavoriteIDs: Set(document.items.map(\.id)).union(document.items.map { selectionID(for: $0) }),
            validCollectionIDs: Set(document.collections.map(\.id))
        )
    }

    // MARK: - Commit

    /// Applies local edits atomically against the latest persisted document.
    /// Network-backed commands commit separately through FavoriteCommands.
    @discardableResult
    func commit<Result: Sendable>(
        _ transform: @escaping @Sendable (inout FavoriteLibraryDocument) throws -> Result
    ) async -> Result? {
        do {
            let (result, updatedDocument) = try await libraryStore.update { document in
                let result = try transform(&document)
                return (result, document)
            }
            document = updatedDocument
            errorMessage = nil
            return result
        } catch {
            presentCommitFailure(error)
            return nil
        }
    }

    private func presentCommitFailure(_ error: any Error) {
        guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
        YamiboLog.persistence.error("Favorite library document commit failed: \(error.localizedDescription)")
        errorMessage = error.localizedDescription
        errorDetails = LoadFailureDetails(error: error)
    }

    var selectionSourceLocation: FavoriteLocation {
        if let selectedCollection {
            .collection(categoryID: selectedCollection.categoryID, collectionID: selectedCollection.id)
        } else {
            .category(selectedCategoryID)
        }
    }

    // MARK: - Persistence

    private func persistNavigationState() {
        guard document.categories.contains(where: { $0.id == selectedCategoryID }) else { return }
        let categoryID = selectedCategoryID
        let validCollectionID = selectedCollectionID.flatMap { id in
            document.collections.contains { $0.id == id && $0.categoryID == categoryID } ? id : nil
        }
        Task {
            do {
                try await settingsStore.update {
                    $0.favorites.selectedCategoryID = categoryID
                    $0.favorites.selectedCollectionID = validCollectionID
                }
            } catch {
                YamiboLog.persistence.error("Failed to persist favorites navigation state: \(error.localizedDescription)")
            }
        }
    }

    /// Persists the current view preferences; on failure runs `rollback` and
    /// reports the error.
    private func persistViewPreferences(
        mutate: @escaping @Sendable (inout AppSettings) -> Void,
        rollback: @escaping @MainActor () -> Void
    ) {
        Task {
            do {
                try await settingsStore.update(mutate)
            } catch {
                YamiboLog.persistence.error("Failed to persist favorites view preferences: \(error.localizedDescription)")
                await MainActor.run {
                    rollback()
                    if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                        errorMessage = error.localizedDescription
                        errorDetails = LoadFailureDetails(error: error)
                    }
                }
            }
        }
    }

}

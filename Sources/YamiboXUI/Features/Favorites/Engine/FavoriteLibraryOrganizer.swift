import Foundation
import Observation
import YamiboXCore

enum CategoryMoveDirection: Sendable {
    case up
    case down
}

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
        didSet { refreshDerivedState() }
    }
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
    internal(set) var selectedCollectionID: String? {
        didSet {
            selection.clearSelection()
            refreshDerivedState()
            persistNavigationState()
        }
    }
    /// Non-nil while a smart-comic card's "查看归档收藏" detail page is open —
    /// the effective title (`FavoriteCardProjection.resolvedTitle`) every
    /// member on that page currently resolves to. Despite the property's
    /// name this is not always an actually-resolved `MangaDirectory`'s
    /// `cleanBookName` — it can equally be a locally-guessed clean title for
    /// a still-unresolved favorite (see `resolvedTitle`'s doc comment).
    /// Mirrors `selectedCollectionID`'s own navigation-state shape but is
    /// deliberately not persisted through `SettingsStore` (see
    /// `persistNavigationState()`): this scope is a live identity, not
    /// durable navigation state worth restoring across launches.
    private(set) var selectedMergedGroupCleanBookName: String? = nil {
        didSet {
            selection.clearSelection()
            refreshDerivedState()
        }
    }
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
    /// Backs `LocalFavoritesRootBackground` — only ever consumed by the root
    /// favorites screen (see `LocalFavoritesOrganizationView`), never by the
    /// pushed collection/merged-group detail pages.
    private(set) var backgroundSettings = FavoriteBackgroundSettings()
    private(set) var backgroundImageData: Data?
    var errorMessage: String?
    /// Short-lived toast feedback (single-item sync results and similar).
    var transientMessage: String?
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
    let contentCoverStore: ContentCoverStore
    let mangaDirectoryStore: MangaDirectoryStore?
    private let favoriteBackgroundImageStore: FavoriteBackgroundImageStore
    let makeForumThreadReaderRepository: (@Sendable () async -> ForumThreadReaderRepository)?
    private let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    let remoteDeleter: YamiboRemoteFavoriteDeleter

    @ObservationIgnored private var readingProgress: [ReadingProgressRecord] = []
    /// Resolved cover URLs and text-cover-forced flags for everything the
    /// cards can display, keyed by the SAME `ContentCoverKey` each card's
    /// `contentCoverKey` resolves — per-favorite `.thread(tid:)` entries
    /// plus `.smartManga(cleanBookName:)` entries for resolved directories
    /// (decision #13/#16). A single keyspace shared with `toggleTextCover`'s
    /// write path, so the row a card displays and the row its cover actions
    /// touch are the same by construction (two parallel string-keyed maps
    /// here once let a smart card's text-cover toggle write a `.thread` row
    /// its own display never read).
    // Cover lane state, owned by FavoriteLibraryOrganizer+Covers.swift.
    @ObservationIgnored var coverLookup = ContentCoverLookup()
    /// Bumped by every `coverLookup` write, including `toggleTextCover`'s
    /// optimistic update. `reload()`/`reloadContentCovers()`/
    /// `reloadBoardReaderSettings()`/`reloadMangaDirectories()` each capture
    /// this before their `await`-heavy cover-store round trips and re-check
    /// it before applying the result: those round trips read one key at a
    /// time, so a slow one can straddle a later write and still resolve
    /// after it. If the revision moved on while it was reading, a fresher
    /// write already landed and applying this now-stale snapshot would
    /// silently revert it — e.g. toggling a smart card's text cover and
    /// then, in the same instant, toggling the underlying thread's own
    /// cover from an expanded archive view could otherwise have the first
    /// toggle's late-arriving notification-driven reload clobber the second
    /// toggle's just-applied state back to "not forced". Skipping a stale
    /// refresh is harmless — the next change notification settles it.
    @ObservationIgnored var coverLookupRevision = 0
    /// tid → resolved `MangaDirectory`, for virtual favorites grouping
    /// (smart-comic-mode decision #3/#5). Populated only at `load()`/
    /// `reload()` via one batched `MangaDirectoryStore.directories
    /// (containingTIDs:)` call — never recomputed per render (the design
    /// doc's performance constraint #2).
    @ObservationIgnored var mangaDirectoriesByTID: [String: MangaDirectory] = [:]
    /// Snapshot of the per-board reader configuration taken at the same
    /// load/reload as `mangaDirectoriesByTID`, so the two are always
    /// consistent with each other for a given derivation.
    @ObservationIgnored var boardReaderSettings = BoardReaderSettings()
    /// Snapshot of `settings.favorites.smartMangaBulkDeleteEnabled`, kept
    /// live alongside `boardReaderSettings` (see `settingsUpdatesTask`) so
    /// `hasDeletableSelection` and `LocalFavoriteCardActions.standard(...)`
    /// — both synchronous reads — see a change made from Settings without
    /// waiting for an unrelated reload.
    @ObservationIgnored private(set) var smartMangaBulkDeleteEnabled = true
    @ObservationIgnored private var libraryUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var progressUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var coverUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var settingsUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var mangaDirectoryUpdatesTask: Task<Void, Never>?
    @ObservationIgnored var mangaCoverBackfillTask: Task<Void, Never>?
    @ObservationIgnored var attemptedMangaCoverTargetIDs: Set<String> = []

    init(
        libraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        settingsStore: SettingsStore,
        contentCoverStore: ContentCoverStore,
        favoriteBackgroundImageStore: FavoriteBackgroundImageStore,
        mangaDirectoryStore: MangaDirectoryStore? = nil,
        makeForumThreadReaderRepository: (@Sendable () async -> ForumThreadReaderRepository)? = nil,
        makeFavoriteRepository: @escaping @Sendable () async -> FavoriteRepository,
        remoteFavoriteDeleteHandler: (([FavoriteItem]) async throws -> Void)? = nil
    ) {
        self.libraryStore = libraryStore
        self.readingProgressStore = readingProgressStore
        self.settingsStore = settingsStore
        self.contentCoverStore = contentCoverStore
        self.favoriteBackgroundImageStore = favoriteBackgroundImageStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.makeForumThreadReaderRepository = makeForumThreadReaderRepository
        self.makeFavoriteRepository = makeFavoriteRepository
        remoteDeleter = YamiboRemoteFavoriteDeleter(
            makeFavoriteRepository: makeFavoriteRepository,
            overrideHandler: remoteFavoriteDeleteHandler
        )
        libraryUpdatesTask = StoreChangeObservation.task(
            changes: { [store = libraryStore] in store.changes() },
            changeID: { [store = libraryStore] in store.changeID }
        ) { [weak self] in
            await self?.reload()
        }
        progressUpdatesTask = StoreChangeObservation.task(
            changes: { [store = readingProgressStore] in store.changes() },
            changeID: { [store = readingProgressStore] in store.changeID }
        ) { [weak self] in
            await self?.reloadReadingProgress()
        }
        coverUpdatesTask = StoreChangeObservation.task(
            changes: { [store = contentCoverStore] in store.changes() },
            changeID: { [store = contentCoverStore] in store.changeID }
        ) { [weak self] in
            await self?.reloadContentCovers()
        }
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
            await self?.reloadFavoriteBackground()
            await self?.reloadSmartMangaToggleSettings()
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
        libraryUpdatesTask?.cancel()
        progressUpdatesTask?.cancel()
        coverUpdatesTask?.cancel()
        settingsUpdatesTask?.cancel()
        mangaDirectoryUpdatesTask?.cancel()
        mangaCoverBackfillTask?.cancel()
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

    /// All favorite items, for tag-association-count sorting in the tag
    /// picker. Views go through the organizer's own surface rather than
    /// reaching into `document` directly.
    var favoriteItems: [FavoriteItem] {
        document.items
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
        let selectedItems = derived.cards
            .map(\.item)
            .filter { selection.selectedFavoriteIDs.contains($0.id) }
        guard let first = selectedItems.first else { return [] }
        return selectedItems.dropFirst().reduce(Set(first.tagIDs)) { partialResult, item in
            partialResult.intersection(Set(item.tagIDs))
        }
    }

    // MARK: - Loading

    func load() async {
        readingProgress = await readingProgressStore.loadAll()
        let loadedDocument: FavoriteLibraryDocument
        do {
            loadedDocument = try await libraryStore.load()
        } catch {
            // Keep whatever the UI currently shows; an empty placeholder here
            // would read as "all favorites gone".
            errorMessage = error.localizedDescription
            return
        }
        let threadCovers = await loadContentCovers(for: loadedDocument.items)
        let settings = await settingsStore.load()
        boardReaderSettings = settings.boardReader
        smartMangaBulkDeleteEnabled = settings.favorites.smartMangaBulkDeleteEnabled
        smartMangaBadgeEnabled = settings.favorites.smartMangaBadgeEnabled
        mangaDirectoriesByTID = await resolveMangaDirectories(for: loadedDocument.items, boardReaderSettings: boardReaderSettings)
        coverLookup = threadCovers.merging(
            await smartMangaCoverLookup(for: Array(Set(mangaDirectoriesByTID.values)))
        )
        coverLookupRevision += 1
        display = FavoriteLibraryDisplayState(
            layoutMode: settings.favorites.layoutMode,
            showsCategoryCounts: settings.favorites.showsCategoryCounts
        )
        await applyBackgroundSettings(settings.favorites.background)
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
    }

    func reload() async {
        guard let loadedDocument = try? await libraryStore.load() else {
            // Transient read failure: keep the current document on screen and
            // let the next change notification retry.
            return
        }
        let expectedCoverRevision = coverLookupRevision
        let threadCovers = await loadContentCovers(for: loadedDocument.items)
        // Only the Smart Comic Mode snapshot is refreshed here — unlike
        // `load()`, `reload()` deliberately never re-applies
        // `settings.favorites` (sort order/layout/etc.) so a background
        // reload triggered by an unrelated favorite/progress/cover change
        // can't clobber the sort order the user may have just changed live
        // in this session.
        let settings = await settingsStore.load()
        boardReaderSettings = settings.boardReader
        mangaDirectoriesByTID = await resolveMangaDirectories(for: loadedDocument.items, boardReaderSettings: boardReaderSettings)
        let smartCovers = await smartMangaCoverLookup(for: Array(Set(mangaDirectoriesByTID.values)))
        // Same staleness guard as `reloadContentCovers()`: this read-then-
        // apply spans several awaits, so a faster, more recent `coverLookup`
        // write (an optimistic `toggleTextCover`, or another reload) can
        // land while this one is still in flight. Applying this snapshot
        // then would revert that fresher write.
        if coverLookupRevision == expectedCoverRevision {
            coverLookup = threadCovers.merging(smartCovers)
            coverLookupRevision += 1
        }
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

    private func reloadReadingProgress() async {
        readingProgress = await readingProgressStore.loadAll()
        refreshDerivedState()
    }

    /// Re-derives `coverLookup` in response to *any*
    /// `ContentCoverStore.changes()` element — including ones this same
    /// organizer's own `toggleTextCover` just caused, since that call posts
    /// through the store like any other writer. `loadContentCovers`/
    /// `smartMangaCoverLookup` read one key at a time, each its own `await`,
    /// so this can start before and finish after a later, faster write (e.g.
    /// `toggleTextCover`'s own optimistic update). Guarded on
    /// `coverLookupRevision` so that a stale snapshot never wins a race
    /// against a fresher one — see the property's doc comment.
    private func reloadContentCovers() async {
        let expectedRevision = coverLookupRevision
        let threadCovers = await loadContentCovers(for: document.items)
        let smartCovers = await smartMangaCoverLookup(for: Array(Set(mangaDirectoriesByTID.values)))
        guard coverLookupRevision == expectedRevision else { return }
        coverLookup = threadCovers.merging(smartCovers)
        coverLookupRevision += 1
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
        let expectedRevision = coverLookupRevision
        let smartCovers = await smartMangaCoverLookup(for: Array(Set(mangaDirectoriesByTID.values)))
        // See `coverLookupRevision`'s doc comment: skip applying this slice
        // if a fresher `coverLookup` write landed while it was being read,
        // rather than clobbering that write with this now-stale one.
        if coverLookupRevision == expectedRevision {
            coverLookup.replaceSmartMangaSlice(with: smartCovers)
            coverLookupRevision += 1
        }
        refreshDerivedState()
        scheduleMangaCoverBackfill(for: document.items)
    }

    /// Re-derives `backgroundSettings`/`backgroundImageData` in response to
    /// *any* `SettingsStore.changes()` element, mirroring
    /// `reloadBoardReaderSettings()`'s diff-guarded shape — this is the only
    /// path that keeps the root favorites background in sync with an edit
    /// made from Settings, since the favorites tab's `FavoriteLibraryOrganizer`
    /// is constructed once for the app's lifetime and never reloads on tab
    /// reselect.
    private func reloadFavoriteBackground() async {
        let settings = await settingsStore.load()
        guard settings.favorites.background != backgroundSettings else { return }
        await applyBackgroundSettings(settings.favorites.background)
    }

    /// Re-derives the favorites-slice smart-manga toggles
    /// (`smartMangaBulkDeleteEnabled`/`smartMangaBadgeEnabled`) in response
    /// to *any* `SettingsStore.changes()` element, mirroring
    /// `reloadFavoriteBackground()`'s diff-guarded shape — kept in sync live
    /// so flipping either Settings switch while Favorites is already open
    /// immediately updates `hasDeletableSelection`/the long-press menu/the
    /// sparkles badge without waiting for an unrelated reload. Each flag is
    /// diff-guarded separately so an unrelated settings save never publishes
    /// a spurious change of the observable badge flag.
    private func reloadSmartMangaToggleSettings() async {
        let settings = await settingsStore.load()
        if settings.favorites.smartMangaBulkDeleteEnabled != smartMangaBulkDeleteEnabled {
            smartMangaBulkDeleteEnabled = settings.favorites.smartMangaBulkDeleteEnabled
        }
        if settings.favorites.smartMangaBadgeEnabled != smartMangaBadgeEnabled {
            smartMangaBadgeEnabled = settings.favorites.smartMangaBadgeEnabled
        }
    }

    private func applyBackgroundSettings(_ newValue: FavoriteBackgroundSettings) async {
        backgroundSettings = newValue
        backgroundImageData = await favoriteBackgroundImageStore.loadData(imageID: newValue.imageID)
    }

    /// Re-derives the manga-directory-dependent slice of state
    /// (`mangaDirectoriesByTID`/`coverLookup`'s `.smartManga` slice) in
    /// response to `MangaDirectoryStore.changes()` -- e.g.
    /// resolving a previously-unresolved manga favorite's directory for the
    /// first time (`saveDirectory`), or renaming a directory from the manga
    /// reader's directory page (`renameDirectory`). Without this, a newly-
    /// resolved directory's merge/cover (or a rename's effect on a merged
    /// card's displayed `cleanBookName`/`.smartManga` cover) would stay stale
    /// in an already-open Favorites tab until some unrelated
    /// favorite/progress/cover/settings change happened to trigger a
    /// full reload.
    ///
    /// Also reloads `readingProgress` -- `MangaDirectoryStore
    /// .renameRelatedStructuredMetadata` cascades a rename into the
    /// `reading_progress` table too (directory-level progress rows get
    /// migrated to the new clean book name), so without this an
    /// already-loaded `readingProgress` array would keep referencing the old
    /// identity and show no/stale progress on a card immediately after a
    /// rename, until some other reload happened to refresh it.
    private func reloadMangaDirectories() async {
        mangaDirectoriesByTID = await resolveMangaDirectories(for: document.items, boardReaderSettings: boardReaderSettings)
        let expectedRevision = coverLookupRevision
        let smartCovers = await smartMangaCoverLookup(for: Array(Set(mangaDirectoriesByTID.values)))
        // See `coverLookupRevision`'s doc comment: skip applying this slice
        // if a fresher `coverLookup` write landed while it was being read,
        // rather than clobbering that write with this now-stale one.
        if coverLookupRevision == expectedRevision {
            coverLookup.replaceSmartMangaSlice(with: smartCovers)
            coverLookupRevision += 1
        }
        readingProgress = await readingProgressStore.loadAll()
        refreshDerivedState()
    }

    // MARK: - Categories

    /// Pushes one favorite item to Yamibo (card context menu action).
    func pushItemToYamibo(_ item: FavoriteItem) async {
        do {
            let repository = await makeFavoriteRepository()
            let result = try await FavoriteQuickActions.pushFavoriteItemToYamibo(
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
            errorMessage = error.localizedDescription
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
    func openMergedGroup(cleanBookName: String) {
        selectedMergedGroupCleanBookName = cleanBookName
    }

    /// Mirrors `closeCollection()` exactly.
    func closeMergedGroup() {
        selectedMergedGroupCleanBookName = nil
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
        let currentLocation = selectionSourceLocation
        let deleter = remoteDeleter
        await commit { document in
            guard let latestItem = document.items.first(where: { $0.id == item.id }) else {
                throw CommitAbort()
            }
            switch scope {
            case .currentLocation:
                if latestItem.locations.count > 1 {
                    _ = document.removeLocation(currentLocation, from: latestItem.target)
                }
            case .everywhere:
                if removeRemote {
                    try await deleter.deleteRemoteFavorites(for: [latestItem])
                }
                document.removeItem(target: latestItem.target)
            }
        }
    }

    // MARK: - Display and sort preferences

    func updateLayoutMode(_ value: FavoriteLibraryLayoutMode) {
        guard value != display.layoutMode else { return }
        let previous = display.layoutMode
        display.layoutMode = value
        persistViewPreferences {
            if self.display.layoutMode == value {
                self.display.layoutMode = previous
            }
        }
    }

    func updateShowsCategoryCounts(_ value: Bool) {
        guard value != display.showsCategoryCounts else { return }
        let previous = display.showsCategoryCounts
        display.showsCategoryCounts = value
        persistViewPreferences {
            if self.display.showsCategoryCounts == value {
                self.display.showsCategoryCounts = previous
            }
        }
    }

    func updateSortOrder(_ value: LocalFavoriteLibrarySortOrder) {
        guard value != filter.sortOrder else { return }
        let previous = filter.sortOrder
        filter.sortOrder = value
        persistViewPreferences {
            if self.filter.sortOrder == value {
                self.filter.sortOrder = previous
            }
        }
    }

    func updateSortDescending(_ value: Bool) {
        guard value != filter.sortDescending else { return }
        let previous = filter.sortDescending
        filter.sortDescending = value
        persistViewPreferences {
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
        guard !isCoalescingDerivedRefresh else {
            needsCoalescedDerivedRefresh = true
            return
        }
        derived = LocalFavoriteLibraryDerivation.derive(
            LocalFavoriteLibraryDerivation.Inputs(
                document: document,
                selectedCategoryID: selectedCategoryID,
                selectedCollectionID: selectedCollectionID,
                filter: filter,
                readingProgress: readingProgress,
                coverURLsByKey: coverLookup.urlsByKey,
                textCoverForcedKeys: coverLookup.forcedKeys,
                mangaDirectoriesByTID: mangaDirectoriesByTID,
                boardReaderSettings: boardReaderSettings,
                memberScopeCleanBookName: selectedMergedGroupCleanBookName
            )
        )
        // `derived` can now be scoped by an open merged group even while no
        // collection is open, so the old `selectedCollectionID == nil`
        // shortcut alone is no longer sufficient — it must also gate on
        // `selectedMergedGroupCleanBookName` (see `isBrowsingUnscopedRoot`),
        // or `rootDerived` would silently inherit the merged-group scope in
        // that case (opening a merged group's detail page directly from the
        // root, not from inside a collection) and defeat the whole point of
        // `rootDerived`.
        rootDerived = isBrowsingUnscopedRoot
            ? derived
            : LocalFavoriteLibraryDerivation.derive(
                LocalFavoriteLibraryDerivation.Inputs(
                    document: document,
                    selectedCategoryID: selectedCategoryID,
                    selectedCollectionID: nil,
                    filter: filter,
                    readingProgress: readingProgress,
                    coverURLsByKey: coverLookup.urlsByKey,
                    textCoverForcedKeys: coverLookup.forcedKeys,
                    mangaDirectoriesByTID: mangaDirectoriesByTID,
                    boardReaderSettings: boardReaderSettings
                    // `memberScopeCleanBookName` intentionally omitted (nil
                    // default): `rootDerived` must never narrow to this scope.
                )
            )
        selection.prune(
            validFavoriteIDs: Set(document.items.map(\.id)),
            validCollectionIDs: Set(document.collections.map(\.id))
        )
    }

    // MARK: - Commit

    private struct CommitAbort: Error {}

    /// Loads the latest document, applies `transform`, saves, and republishes.
    /// Throwing aborts without saving; errors surface through `errorMessage`.
    /// A failed load aborts the same way — the transform must never run
    /// against a placeholder document, or the save would wipe the library.
    /// (The transform can await remote work, so this stays load-modify-save
    /// rather than `FavoriteLibraryStore.update`.)
    @discardableResult
    func commit<Result>(
        _ transform: (inout FavoriteLibraryDocument) async throws -> Result
    ) async -> Result? {
        do {
            var updatedDocument = try await libraryStore.load()
            let result = try await transform(&updatedDocument)
            try await libraryStore.save(updatedDocument)
            document = updatedDocument
            errorMessage = nil
            return result
        } catch is CommitAbort {
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            YamiboLog.persistence.error("Favorite library document commit failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return nil
        }
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
            var settings = await settingsStore.load()
            guard settings.favorites.selectedCategoryID != categoryID
                    || settings.favorites.selectedCollectionID != validCollectionID else { return }
            settings.favorites.selectedCategoryID = categoryID
            settings.favorites.selectedCollectionID = validCollectionID
            do {
                try await settingsStore.save(settings)
            } catch {
                YamiboLog.persistence.error("Failed to persist favorites navigation state: \(error.localizedDescription)")
            }
        }
    }

    /// Persists the current view preferences; on failure runs `rollback` and
    /// reports the error.
    private func persistViewPreferences(rollback: @escaping @MainActor () -> Void) {
        let display = display
        let sortOrder = filter.sortOrder
        let sortDescending = filter.sortDescending
        Task {
            var settings = await settingsStore.load()
            settings.favorites.layoutMode = display.layoutMode
            settings.favorites.showsCategoryCounts = display.showsCategoryCounts
            settings.favorites.sortOrder = sortOrder
            settings.favorites.sortDescending = sortDescending
            do {
                try await settingsStore.save(settings)
            } catch {
                YamiboLog.persistence.error("Failed to persist favorites view preferences: \(error.localizedDescription)")
                await MainActor.run {
                    rollback()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

}

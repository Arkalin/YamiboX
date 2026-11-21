import Foundation
import Observation
import YamiboXCore

enum LocalFavoriteDeleteScope: Equatable {
    case currentLocation
    case everywhere
}

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
    private(set) var selectedMergedGroupKey: String? = nil
    private var unresolvedMergedGroupThreadIDs: Set<String>?
    var filter = LocalFavoriteFilterState() {
        didSet {
            guard filter != oldValue else { return }
            refreshDerivedState()
        }
    }
    private(set) var derived = LocalFavoriteDerivedState()
    private(set) var rootDerived = LocalFavoriteDerivedState()
    private(set) var display = FavoriteLibraryDisplayState()
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
    var transientFeedback: TransientFeedback?
    var transientMessage: String? {
        get { transientFeedback?.message }
        set { transientFeedback = newValue.map { TransientFeedback(message: $0) } }
    }
    var removeRemotePrompt: LocalFavoriteRemoveRemotePrompt?

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
    @ObservationIgnored var mangaDirectoriesByTID: [String: MangaDirectory] = [:] {
        didSet { mangaDirectoriesRevision &+= 1 }
    }
    private(set) var mangaDirectoriesRevision: UInt64 = 0
    var unreadMangaDirectoriesByTID: [String: MangaDirectory] = [:] {
        didSet { unreadDirectoriesRevision &+= 1 }
    }
    private(set) var unreadDirectoriesRevision: UInt64 = 0
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

    var selectionLocationSnapshot: LocalFavoriteLocationMembershipSnapshot {
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
        let items = document.items
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
        settingsUpdatesTask = StoreChangeObservation.task(
            changes: { [store = settingsStore] in store.changes() },
            changeID: { [store = settingsStore] in store.changeID }
        ) { [weak self] in
            await self?.reloadBoardReaderSettings()
            await self?.reloadFavoriteSettingsSnapshots()
        }
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

    var favoriteItems: [FavoriteItem] { document.items }

    @ObservationIgnored private var cachedTagAssociationCounts: [String: Int]?

    var favoriteTagAssociationCounts: [String: Int] {
        let items = document.items
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

    var selectedFavoritesCanRemoveCurrentLocation: Bool {
        guard selection.selectedCollectionCount == 0 else { return false }
        return derived.cards.contains { card in
            selection.selectedFavoriteIDs.contains(card.id) && card.item.locations.count > 1
        }
    }

    var commonTagIDsForSelection: Set<String> {
        let selectedIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let selectedItems = document.items.filter { selectedIDs.contains($0.id) }
        guard let first = selectedItems.first else { return [] }
        return selectedItems.dropFirst().reduce(Set(first.tagIDs)) { partialResult, item in
            partialResult.intersection(Set(item.tagIDs))
        }
    }

    func load() async {
        observeReadingProgressIfNeeded()
        let loadedDocument: FavoriteLibraryDocument
        do {
            loadedDocument = try await libraryStore.load()
        } catch {
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
            return
        }
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

    private func reloadBoardReaderSettings() async {
        let settings = await settingsStore.load()
        guard settings.boardReader != boardReaderSettings else { return }
        boardReaderSettings = settings.boardReader
        mangaDirectoriesByTID = await resolveMangaDirectories(for: document.items, boardReaderSettings: boardReaderSettings)
        await covers.refreshSmartManga(Array(Set(mangaDirectoriesByTID.values)))
        refreshDerivedState()
        scheduleMangaCoverBackfill(for: document.items)
    }

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

    func closeMergedGroup() {
        selectedMergedGroupKey = nil
        unresolvedMergedGroupThreadIDs = nil
        selection.clearSelection()
        refreshDerivedState()
    }

    private func resolveUnresolvedMergedGroupScope() {
        guard var threadIDs = unresolvedMergedGroupThreadIDs, let key = selectedMergedGroupKey else { return }
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
        guard directories.count == survivingMembers.count, ids.count == 1, let id = ids.first else { return }
        selectedMergedGroupKey = id.rawValue
        unresolvedMergedGroupThreadIDs = nil
    }

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

    @ObservationIgnored private var isCoalescingDerivedRefresh = false
    @ObservationIgnored private var needsCoalescedDerivedRefresh = false
    @ObservationIgnored private var isBookPresentationActive = false
    @ObservationIgnored private var needsBookPresentationRefresh = false

    func setBookPresentationActive(_ active: Bool) {
        isBookPresentationActive = active
        if active {
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

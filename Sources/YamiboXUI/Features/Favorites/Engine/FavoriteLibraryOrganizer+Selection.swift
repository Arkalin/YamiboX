import Foundation
import YamiboXCore

extension FavoriteLibraryOrganizer {

    var isBrowsingUnscopedRoot: Bool {
        selectedCollectionID == nil && selectedMergedGroupKey == nil
    }

    func toggleCollectionSelection(id: String) {
        guard isBrowsingUnscopedRoot else { return }
        selection.toggleCollectionSelection(id: id)
    }

    private func isSmartCardFavoriteID(_ id: String) -> Bool {
        guard selectedMergedGroupKey == nil else { return false }
        if mangaDirectoriesByTID.values.contains(where: { $0.id.rawValue == id }) { return true }
        guard
              let item = document.items.first(where: { $0.id == id }) else { return false }
        return item.target.kind == .mangaThread && boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID)
    }

    var hasDeletableSelection: Bool {
        selection.selectedCollectionCount > 0
            || (smartMangaBulkDeleteEnabled && !selection.selectedFavoriteIDs.isEmpty)
            || selection.selectedFavoriteIDs.contains { !isSmartCardFavoriteID($0) }
    }

    func expandedSelectionFavoriteIDs(_ favoriteIDs: Set<String>) -> Set<String> {
        guard selectedMergedGroupKey == nil else { return favoriteIDs }
        let itemsByEffectiveTitle = LocalFavoriteLibraryProjection.mangaThreadItemsByGroupKey(
            in: document.items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )
        let itemsByID = Dictionary(document.items.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var expanded = favoriteIDs
        for id in favoriteIDs {
            if let members = itemsByEffectiveTitle[id] {
                expanded.remove(id)
                expanded.formUnion(members.map(\.id))
                continue
            }
            guard let item = itemsByID[id],
                  item.target.kind == .mangaThread,
                  boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID) else { continue }
            let directory = mangaDirectoriesByTID[item.target.threadID ?? ""]
            let effectiveTitle = FavoriteCardProjection.groupKey(item: item, mangaDirectory: directory)
            let archived = itemsByEffectiveTitle[effectiveTitle] ?? []
            expanded.formUnion(archived.map(\.id))
        }
        return expanded
    }

    func selectionID(for item: FavoriteItem) -> String {
        guard selectedMergedGroupKey == nil,
              item.target.kind == .mangaThread,
              boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID),
              let directory = mangaDirectoriesByTID[item.target.threadID ?? ""] else { return item.id }
        return directory.id.rawValue
    }

    private var selectableFavoriteIDs: [String] {
        derived.cards.map(\.id)
    }

    func selectAllVisible() {
        selection.selectAll(
            favoriteIDs: selectableFavoriteIDs,
            collectionIDs: isBrowsingUnscopedRoot ? derived.visibleCollections.map(\.id) : []
        )
    }

    var isAllVisibleSelected: Bool {
        let favoriteIDs = selectableFavoriteIDs
        let collectionIDs = isBrowsingUnscopedRoot ? derived.visibleCollections.map(\.id) : []
        let totalCount = favoriteIDs.count + collectionIDs.count
        guard totalCount > 0 else { return false }
        let selectedCount = favoriteIDs.filter(selection.selectedFavoriteIDs.contains).count
            + collectionIDs.filter(selection.selectedCollectionIDs.contains).count
        return selectedCount == totalCount
    }

    var hasVisibleSelectableEntries: Bool {
        !selectableFavoriteIDs.isEmpty || (isBrowsingUnscopedRoot && !derived.visibleCollections.isEmpty)
    }

    func toggleSelectAllVisible() {
        if isAllVisibleSelected {
            selection.clearSelection()
        } else {
            selectAllVisible()
        }
    }

    @discardableResult
    func createCollectionFromSelection(name: String, color: FavoriteCollectionColor = .gray) async -> LocalFavoriteCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let categoryID = selectedCategoryID
        let source = selectionSourceLocation
        guard !trimmed.isEmpty, !favoriteIDs.isEmpty else { return nil }
        let collection = await commit { document in
            let collection = document.createCollection(categoryID: categoryID, name: trimmed, color: color)
            document.moveItems(
                ids: favoriteIDs,
                to: .collection(categoryID: collection.categoryID, collectionID: collection.id),
                removing: source
            )
            return collection
        }
        guard let collection else { return nil }
        selectedCollectionID = collection.id
        selection.exitSelectionMode()
        return collection
    }

    func moveSelectionToCategory(id categoryID: String) async {
        guard selection.selectedEntryCount > 0 else { return }
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let collectionIDs = selection.selectedCollectionIDs
        let source = selectionSourceLocation
        let committed: Void? = await commit { document in
            for collectionID in collectionIDs {
                document.moveCollection(id: collectionID, toCategoryID: categoryID)
            }
            document.moveItems(ids: favoriteIDs, to: .category(categoryID), removing: source)
        }
        guard committed != nil else { return }
        selectedCategoryID = categoryID
        selection.exitSelectionMode()
    }

    func moveSelectionToCollection(id collectionID: String) async {
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let source = selectionSourceLocation
        guard !favoriteIDs.isEmpty,
              let collection = document.collections.first(where: { $0.id == collectionID }) else { return }
        let committed: Void? = await commit { document in
            document.moveItems(
                ids: favoriteIDs,
                to: .collection(categoryID: collection.categoryID, collectionID: collection.id),
                removing: source
            )
        }
        guard committed != nil else { return }
        selectedCategoryID = collection.categoryID
        selectedCollectionID = collection.id
        selection.exitSelectionMode()
    }

    func addSelectionToCategory(id categoryID: String) async {
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        guard !favoriteIDs.isEmpty else { return }
        let committed: Void? = await commit { document in
            document.moveItems(ids: favoriteIDs, to: .category(categoryID), removing: nil)
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    func addSelectionToCollection(id collectionID: String) async {
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        guard !favoriteIDs.isEmpty,
              let collection = document.collections.first(where: { $0.id == collectionID }) else { return }
        let committed: Void? = await commit { document in
            document.moveItems(
                ids: favoriteIDs,
                to: .collection(categoryID: collection.categoryID, collectionID: collection.id),
                removing: nil
            )
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    func selectionLocationState(_ location: FavoriteLocation) -> LocalFavoriteLocationTriState {
        selectionLocationSnapshot.state(location)
    }

    func setSelectionLocation(_ location: FavoriteLocation, included: Bool) async {
        let ids = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        guard !ids.isEmpty else { return }
        _ = await commit { document in
            if included {
                document.moveItems(ids: ids, to: location, removing: nil)
            } else {
                document.removeItems(ids: ids, from: location)
            }
        }
    }

    func removeSelectionFromCurrentLocation() async {
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let source = selectionSourceLocation
        guard !favoriteIDs.isEmpty else { return }
        let committed: Void? = await commit { document in
            document.removeItems(ids: favoriteIDs, from: source)
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    func dissolveSelectedCollections() async {
        let collectionIDs = selection.selectedCollectionIDs
        guard !collectionIDs.isEmpty else { return }
        let committed: Void? = await commit { document in
            document.dissolveCollections(ids: Array(collectionIDs))
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    func requestDeleteSelection(scope: LocalFavoriteDeleteScope) async {
        switch scope {
        case .currentLocation:
            await deleteSelection(scope: .currentLocation, removeRemote: false)
        case .everywhere:
            let deletableIDs = smartMangaBulkDeleteEnabled
                ? expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
                : selection.selectedFavoriteIDs.filter { !isSmartCardFavoriteID($0) }
            let candidates = document.items.filter { deletableIDs.contains($0.id) }
            switch await resolveRemoveRemoteDecision(candidates: candidates) {
            case .prompt:
                removeRemotePrompt = LocalFavoriteRemoveRemotePrompt(subject: .selection)
            case let .silent(removeRemote):
                await deleteSelection(scope: .everywhere, removeRemote: removeRemote)
            }
        }
    }

    func requestDeleteItem(_ item: FavoriteItem, scope: LocalFavoriteDeleteScope) async {
        switch scope {
        case .currentLocation:
            await deleteItem(item, scope: .currentLocation, removeRemote: false)
        case .everywhere:
            let latestItem = document.items.first { $0.id == item.id } ?? item
            switch await resolveRemoveRemoteDecision(candidates: [latestItem]) {
            case .prompt:
                removeRemotePrompt = LocalFavoriteRemoveRemotePrompt(subject: .item(item))
            case let .silent(removeRemote):
                await deleteItem(item, scope: .everywhere, removeRemote: removeRemote)
            }
        }
    }

    func confirmRemoveRemotePrompt(
        _ prompt: LocalFavoriteRemoveRemotePrompt,
        removeRemote: Bool,
        remember: Bool
    ) async {
        removeRemotePrompt = nil
        if remember {
            await FavoriteCommands.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore)
        }
        switch prompt.subject {
        case let .item(item):
            await deleteItem(item, scope: .everywhere, removeRemote: removeRemote)
        case .selection:
            await deleteSelection(scope: .everywhere, removeRemote: removeRemote)
        }
    }

    private func resolveRemoveRemoteDecision(candidates: [FavoriteItem]) async -> FavoriteRemoveRemoteDecision {
        let canRemoveRemote = candidates.contains(where: \.hasYamiboRemoteCandidate)
        let settings = await settingsStore.load().favorites
        return FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote)
    }

    func deleteSelection(scope: LocalFavoriteDeleteScope, removeRemote: Bool) async {
        guard selection.selectedEntryCount > 0 else { return }
        let allSelectedFavoriteIDs = selection.selectedFavoriteIDs
        let favoriteIDs: Set<String>
        if smartMangaBulkDeleteEnabled {
            favoriteIDs = expandedSelectionFavoriteIDs(allSelectedFavoriteIDs)
        } else {
            let skippedSmartCardFavoriteIDs = allSelectedFavoriteIDs.filter(isSmartCardFavoriteID)
            favoriteIDs = allSelectedFavoriteIDs.subtracting(skippedSmartCardFavoriteIDs)
            if !skippedSmartCardFavoriteIDs.isEmpty {
                transientFeedback = .failure(L10n.string("favorites.bulk_delete_skipped_smart_manga_message"))
            }
        }
        let collectionIDs = selection.selectedCollectionIDs
        guard !favoriteIDs.isEmpty || !collectionIDs.isEmpty else {
            selection.exitSelectionMode()
            return
        }
        let committed = await deleteFavorites(FavoriteDeletionRequest(
            favoriteIDs: favoriteIDs,
            collectionIDs: collectionIDs,
            scope: deletionScope(scope, removeRemote: removeRemote)
        ))
        guard committed else { return }
        selection.exitSelectionMode()
    }
}

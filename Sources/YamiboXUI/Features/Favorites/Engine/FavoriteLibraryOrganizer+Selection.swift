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
        if let card = derived.cards.first(where: { $0.id == id }) {
            if case .projectionGroup = LocalFavoriteCardDeletionTarget(card: card) { return true }
            return false
        }
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
            let directory = mangaDirectoriesByTID[item.target.threadID]
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
              let directory = mangaDirectoriesByTID[item.target.threadID] else { return item.id }
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

    func makeSelectionDeletePlan() -> LocalFavoriteSelectionDeletePlan {
        let selectedIDs = selection.selectedFavoriteIDs
        let deletableIDs = smartMangaBulkDeleteEnabled
            ? expandedSelectionFavoriteIDs(selectedIDs)
            : selectedIDs.filter { !isSmartCardFavoriteID($0) }

        return LocalFavoriteSelectionDeletePlan(
            items: Set(document.items.filter { deletableIDs.contains($0.id) }),
            collections: Set(document.collections.filter { selection.selectedCollectionIDs.contains($0.id) }),
            currentLocation: selectedFavoritesCanRemoveCurrentLocation ? selectionSourceLocation : nil,
            skipsSmartManga: !smartMangaBulkDeleteEnabled && selectedIDs.contains(where: isSmartCardFavoriteID)
        )
    }

    func requestDeleteSelection(_ plan: LocalFavoriteSelectionDeletePlan, scope: LocalFavoriteDeleteScope) async {
        guard validateDeleteSelection(plan) else { return }
        guard !plan.isEmpty else {
            if plan.skipsSmartManga { showSkippedSmartManga() }
            selection.exitSelectionMode()
            return
        }
        switch scope {
        case .currentLocation:
            await deleteSelection(plan, scope: .currentLocation, removeRemote: false)
        case .everywhere:
            let decision = await resolveRemoveRemoteDecision(candidates: Array(plan.items))
            guard validateDeleteSelection(plan) else { return }
            switch decision {
            case .prompt:
                removeRemotePrompt = LocalFavoriteRemoveRemotePrompt(subject: .selection(plan))
            case let .silent(removeRemote):
                await deleteSelection(plan, scope: .everywhere, removeRemote: removeRemote)
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
        guard removeRemotePrompt == nil else { return }
        switch prompt.subject {
        case let .item(item):
            if remember {
                await FavoriteCommands.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore)
            }
            await deleteItem(item, scope: .everywhere, removeRemote: removeRemote)
        case let .selection(plan):
            guard await deleteSelection(plan, scope: .everywhere, removeRemote: removeRemote) else { return }
            if remember {
                await FavoriteCommands.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore)
            }
        }
    }

    private func resolveRemoveRemoteDecision(candidates: [FavoriteItem]) async -> FavoriteRemoveRemoteDecision {
        let canRemoveRemote = candidates.contains(where: \.hasYamiboRemoteCandidate)
        let settings = await settingsStore.load().favorites
        return FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote)
    }

    private func validateDeleteSelection(_ plan: LocalFavoriteSelectionDeletePlan) -> Bool {
        guard makeSelectionDeletePlan() == plan else {
            transientFeedback = .failure(L10n.string("favorites.bulk_delete_selection_changed"))
            return false
        }
        return true
    }

    private func showSkippedSmartManga() {
        transientFeedback = .failure(L10n.string("favorites.bulk_delete_skipped_smart_manga_message"))
    }

    @discardableResult
    private func deleteSelection(
        _ plan: LocalFavoriteSelectionDeletePlan,
        scope: LocalFavoriteDeleteScope,
        removeRemote: Bool
    ) async -> Bool {
        guard validateDeleteSelection(plan) else { return false }
        let deletionScope: FavoriteDeletionRequest.Scope
        switch scope {
        case .currentLocation:
            guard let location = plan.currentLocation else { return false }
            deletionScope = .currentLocation(location)
        case .everywhere:
            deletionScope = .everywhere(removeRemote: removeRemote)
        }
        if plan.skipsSmartManga { showSkippedSmartManga() }
        let committed = await deleteFavorites(FavoriteDeletionRequest(
            favoriteIDs: Set(plan.items.map(\.id)),
            collectionIDs: Set(plan.collections.map(\.id)),
            scope: deletionScope,
            confirmedItems: plan.items,
            confirmedCollections: plan.collections
        ))
        if committed { selection.exitSelectionMode() }
        return committed
    }
}

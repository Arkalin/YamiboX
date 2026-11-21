import Foundation

@MainActor
final class LocalFavoriteBrowseSession: ObservableObject {
    @Published private(set) var isSelectionMode = false
    @Published private(set) var selectedFavoriteIDs: Set<String> = []
    @Published private(set) var selectedCollectionIDs: Set<String> = []

    var selectedFavoriteCount: Int {
        selectedFavoriteIDs.count
    }

    var selectedCollectionCount: Int {
        selectedCollectionIDs.count
    }

    var selectedEntryCount: Int {
        selectedFavoriteIDs.count + selectedCollectionIDs.count
    }

    var canCreateCollectionFromSelection: Bool {
        !selectedFavoriteIDs.isEmpty && selectedCollectionIDs.isEmpty
    }


    func enterSelectionMode() {
        isSelectionMode = true
    }

    func exitSelectionMode() {
        isSelectionMode = false
        clearSelection()
    }

    func clearSelection() {
        selectedFavoriteIDs.removeAll()
        selectedCollectionIDs.removeAll()
    }

    func replaceFavoriteSelection(with ids: Set<String>) {
        selectedFavoriteIDs = ids
    }

    func toggleFavoriteSelection(id: String) {
        isSelectionMode = true
        if selectedFavoriteIDs.contains(id) {
            selectedFavoriteIDs.remove(id)
        } else {
            selectedFavoriteIDs.insert(id)
        }
    }

    func toggleCollectionSelection(id: String) {
        isSelectionMode = true
        if selectedCollectionIDs.contains(id) {
            selectedCollectionIDs.remove(id)
        } else {
            selectedCollectionIDs.insert(id)
        }
    }

    func selectAll(favoriteIDs: [String], collectionIDs: [String]) {
        isSelectionMode = true
        selectedFavoriteIDs.formUnion(favoriteIDs)
        selectedCollectionIDs.formUnion(collectionIDs)
    }

    func prune(validFavoriteIDs: Set<String>, validCollectionIDs: Set<String>) {
        selectedFavoriteIDs.formIntersection(validFavoriteIDs)
        selectedCollectionIDs.formIntersection(validCollectionIDs)
        if selectedEntryCount == 0, isSelectionMode {
            isSelectionMode = false
        }
    }
}

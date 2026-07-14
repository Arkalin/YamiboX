import Foundation

/// Interactive browse session for the favorites screen: multi-selection
/// state. Pure state machine with no persistence dependencies. (Search is a
/// plain live filter through `.searchable`, not a session mode.)
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

    /// Only meaningful for a pure-item selection: creating a collection
    /// moves the selected favorites into it, which has no sensible effect on
    /// a selected collection (collections don't nest).
    var canCreateCollectionFromSelection: Bool {
        !selectedFavoriteIDs.isEmpty && selectedCollectionIDs.isEmpty
    }

    // MARK: - Selection

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

    /// Drops selections that no longer exist in the library document and exits
    /// selection mode when nothing remains selected.
    func prune(validFavoriteIDs: Set<String>, validCollectionIDs: Set<String>) {
        selectedFavoriteIDs.formIntersection(validFavoriteIDs)
        selectedCollectionIDs.formIntersection(validCollectionIDs)
        if selectedEntryCount == 0, isSelectionMode {
            isSelectionMode = false
        }
    }
}

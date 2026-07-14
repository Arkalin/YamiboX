import Foundation
import YamiboXCore

/// Batch item edits used by the favorites organizer when applying
/// selection-based operations to the library document.
extension FavoriteLibraryDocument {
    mutating func moveItems(
        ids selectedIDs: Set<String>,
        to destination: FavoriteLocation,
        removing source: FavoriteLocation?
    ) {
        guard !selectedIDs.isEmpty else { return }
        items = items.map { item in
            guard selectedIDs.contains(item.id) else { return item }
            var item = item
            var locations = item.locations
            if let source, source != destination {
                locations.removeAll { $0 == source }
            }
            locations.append(destination)
            item.locations = Self.normalizedLocations(locations)
            item.updatedAt = .now
            return item
        }
    }

    mutating func removeItems(
        ids selectedIDs: Set<String>,
        from source: FavoriteLocation
    ) {
        guard !selectedIDs.isEmpty else { return }
        items = items.map { item in
            guard selectedIDs.contains(item.id),
                  item.locations.count > 1,
                  item.locations.contains(source) else {
                return item
            }
            var item = item
            item.locations.removeAll { $0 == source }
            item.updatedAt = .now
            return item
        }
    }

    mutating func replaceTags(
        for selectedIDs: Set<String>,
        with tagIDs: Set<String>
    ) {
        let validTagIDs = Set(tags.map(\.id))
        let normalizedTagIDs = tagIDs.filter { validTagIDs.contains($0) }.sorted()
        items = items.map { item in
            guard selectedIDs.contains(item.id) else { return item }
            var item = item
            item.tagIDs = normalizedTagIDs
            item.updatedAt = .now
            return item
        }
    }

    private static func normalizedLocations(_ locations: [FavoriteLocation]) -> [FavoriteLocation] {
        var seen: Set<String> = []
        return locations.filter { seen.insert($0.id).inserted }
    }

    /// New manual order of the non-default categories after moving `id` one
    /// step, or nil when the move is out of bounds.
    func reorderedCategoryIDs(moving id: String, _ direction: CategoryMoveDirection) -> [String]? {
        let nonDefaultCategories = categories
            .filter { !$0.isDefault }
            .sorted { $0.manualOrder == $1.manualOrder ? $0.id < $1.id : $0.manualOrder < $1.manualOrder }
        guard let index = nonDefaultCategories.firstIndex(where: { $0.id == id }) else { return nil }
        let targetIndex = direction == .up ? index - 1 : index + 1
        guard nonDefaultCategories.indices.contains(targetIndex) else { return nil }
        var orderedIDs = nonDefaultCategories.map(\.id)
        orderedIDs.swapAt(index, targetIndex)
        return orderedIDs
    }

    /// New manual order of the collection's category siblings after moving
    /// `id` one step, or nil when the move is out of bounds.
    func reorderedCollectionIDs(moving id: String, _ direction: CategoryMoveDirection) -> (categoryID: String, orderedIDs: [String])? {
        guard let collection = collections.first(where: { $0.id == id }) else { return nil }
        let siblings = collections
            .filter { $0.categoryID == collection.categoryID }
            .sorted { $0.manualOrder == $1.manualOrder ? $0.id < $1.id : $0.manualOrder < $1.manualOrder }
        guard let index = siblings.firstIndex(where: { $0.id == id }) else { return nil }
        let targetIndex = direction == .up ? index - 1 : index + 1
        guard siblings.indices.contains(targetIndex) else { return nil }
        var orderedIDs = siblings.map(\.id)
        orderedIDs.swapAt(index, targetIndex)
        return (collection.categoryID, orderedIDs)
    }
}

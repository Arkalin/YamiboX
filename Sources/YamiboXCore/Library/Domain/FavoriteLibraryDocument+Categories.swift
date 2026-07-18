import Foundation

// Category mutations of the favorites library document. Split from the
// former monolithic FavoriteLibrary.swift; method bodies moved verbatim.
extension FavoriteLibraryDocument {
    public mutating func createCategory(name: String) -> FavoriteCategory {
        let category = FavoriteCategory(
            name: name,
            manualOrder: ((categories.map(\.manualOrder).max() ?? -1) + 1),
            isDefault: false
        )
        categories.append(category)
        categories = Self.normalizedCategories(categories)
        return category
    }

    public mutating func renameCategory(id: String, name: String) {
        guard let index = categories.firstIndex(where: { $0.id == id && !$0.isDefault }) else { return }
        categories[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func reorderCategories(orderedIDs: [String]) {
        let orderByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset + 1) })
        categories = categories.map { category in
            var category = category
            guard !category.isDefault, let order = orderByID[category.id] else { return category }
            category.manualOrder = order
            return category
        }
        categories = Self.normalizedCategories(categories)
    }

    public mutating func deleteCategory(id: String, date: Date = .now) {
        guard categories.contains(where: { $0.id == id && !$0.isDefault }) else { return }
        let defaultLocation = FavoriteLocation.category(defaultCategory.id)
        categories.removeAll { $0.id == id && !$0.isDefault }
        deletedCategoryIDs[id] = date
        // Every collection under this category is cascade-deleted too, and
        // needs its own tombstone — otherwise a stale peer that still has
        // one of them (but already knows the category is gone) would revive
        // it referencing a category id that no longer exists anywhere.
        for collection in collections where collection.categoryID == id {
            deletedCollectionIDs[collection.id] = date
        }
        collections.removeAll { $0.categoryID == id }
        items = items.map { item in
            var item = item
            let remaining = item.locations.filter { $0.categoryID != id }
            guard remaining.count != item.locations.count else { return item }
            item.locations = FavoriteItem.normalizedLocations(remaining.isEmpty ? [defaultLocation] : remaining)
            item.locationsUpdatedAt = date
            item.updatedAt = date
            return item
        }
    }
}

import Foundation

// Collection mutations of the favorites library document. Split from the
// former monolithic FavoriteLibrary.swift; method bodies moved verbatim.
extension FavoriteLibraryDocument {
    public mutating func createCollection(
        categoryID: String,
        name: String,
        color: FavoriteCollectionColor = .gray
    ) -> LocalFavoriteCollection {
        let collection = LocalFavoriteCollection(
            categoryID: categoryID,
            name: name,
            color: color,
            manualOrder: ((collections.filter { $0.categoryID == categoryID }.map(\.manualOrder).max() ?? -1) + 1)
        )
        collections.append(collection)
        return collection
    }

    public mutating func renameCollection(id collectionID: String, name: String) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func recolorCollection(id collectionID: String, color: FavoriteCollectionColor) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[index].color = color
    }

    public mutating func moveCollection(id collectionID: String, toCategoryID categoryID: String) {
        guard categories.contains(where: { $0.id == categoryID }),
              let index = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }
        let previousCategoryID = collections[index].categoryID
        guard previousCategoryID != categoryID else { return }
        collections[index].categoryID = categoryID
        collections[index].manualOrder = ((collections.filter { $0.categoryID == categoryID }.map(\.manualOrder).max() ?? -1) + 1)
        items = items.map { item in
            var item = item
            item.locations = item.locations.map { location in
                location == .collection(categoryID: previousCategoryID, collectionID: collectionID)
                    ? .collection(categoryID: categoryID, collectionID: collectionID)
                    : location
            }
            item.locations = FavoriteItem.normalizedLocations(item.locations)
            return item
        }
    }

    public mutating func reorderCollections(categoryID: String, orderedIDs: [String]) {
        let orderByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        collections = collections.map { collection in
            var collection = collection
            guard collection.categoryID == categoryID, let order = orderByID[collection.id] else { return collection }
            collection.manualOrder = order
            return collection
        }
    }

    public mutating func dissolveCollection(id collectionID: String) {
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return }
        let parentLocation = FavoriteLocation.category(collection.categoryID)
        collections.removeAll { $0.id == collectionID }
        items = items.map { item in
            var item = item
            if item.locations.contains(.collection(categoryID: collection.categoryID, collectionID: collectionID)) {
                item.locations.removeAll { $0 == .collection(categoryID: collection.categoryID, collectionID: collectionID) }
                item.locations = FavoriteItem.normalizedLocations(item.locations + [parentLocation])
            }
            return item
        }
    }
}

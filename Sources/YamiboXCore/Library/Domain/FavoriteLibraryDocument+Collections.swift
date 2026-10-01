import Foundation

// Collection mutations of the favorites library document. Split from the
// former monolithic FavoriteLibrary.swift; method bodies moved verbatim.
extension FavoriteLibraryDocument {
    public mutating func createCollection(
        categoryID: String,
        name: String,
        color: FavoriteCollectionColor = .gray,
        date: Date = .now
    ) -> LocalFavoriteCollection {
        let collection = LocalFavoriteCollection(
            categoryID: categoryID,
            name: name,
            color: color,
            manualOrder: ((collections.filter { $0.categoryID == categoryID }.map(\.manualOrder).max() ?? -1) + 1),
            updatedAt: date
        )
        collections.append(collection)
        return collection
    }

    public mutating func renameCollection(id collectionID: String, name: String, date: Date = .now) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = collections.firstIndex(where: { $0.id == collectionID }),
              collections[index].name != trimmedName else { return }
        collections[index].name = trimmedName
        collections[index].updatedAt = date
    }

    public mutating func recolorCollection(id collectionID: String, color: FavoriteCollectionColor, date: Date = .now) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }),
              collections[index].color != color else { return }
        collections[index].color = color
        collections[index].updatedAt = date
    }

    public mutating func moveCollection(id collectionID: String, toCategoryID categoryID: String, date: Date = .now) {
        guard categories.contains(where: { $0.id == categoryID }),
              let index = collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }
        let previousCategoryID = collections[index].categoryID
        guard previousCategoryID != categoryID else { return }
        collections[index].categoryID = categoryID
        collections[index].manualOrder = ((collections.filter { $0.categoryID == categoryID }.map(\.manualOrder).max() ?? -1) + 1)
        collections[index].updatedAt = date
        items = items.map { item in
            guard item.locations.contains(.collection(categoryID: previousCategoryID, collectionID: collectionID)) else { return item }
            var item = item
            item.locations = item.locations.map { location in
                location == .collection(categoryID: previousCategoryID, collectionID: collectionID)
                    ? .collection(categoryID: categoryID, collectionID: collectionID)
                    : location
            }
            item.locations = FavoriteItem.normalizedLocations(item.locations)
            item.locationsUpdatedAt = date
            item.updatedAt = date
            return item
        }
    }

    public mutating func reorderCollections(categoryID: String, orderedIDs: [String], date: Date = .now) {
        let orderByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        collections = collections.map { collection in
            var collection = collection
            guard collection.categoryID == categoryID,
                  let order = orderByID[collection.id],
                  collection.manualOrder != order else { return collection }
            collection.manualOrder = order
            collection.updatedAt = date
            return collection
        }
    }

    public mutating func dissolveCollection(id collectionID: String, date: Date = .now) {
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return }
        let parentLocation = FavoriteLocation.category(collection.categoryID)
        collections.removeAll { $0.id == collectionID }
        deletedCollectionIDs[collectionID] = date
        items = items.map { item in
            var item = item
            if item.locations.contains(.collection(categoryID: collection.categoryID, collectionID: collectionID)) {
                item.locations.removeAll { $0 == .collection(categoryID: collection.categoryID, collectionID: collectionID) }
                item.locations = FavoriteItem.normalizedLocations(item.locations + [parentLocation])
                item.locationsUpdatedAt = date
                item.updatedAt = date
            }
            return item
        }
    }

    /// Preserves the order of the former per-collection operations while
    /// visiting the item array once. Decoded documents may contain duplicate
    /// collection IDs, so the first collection still determines its parent.
    public mutating func dissolveCollections(
        ids collectionIDs: [String],
        now: () -> Date = { .now }
    ) {
        guard !collectionIDs.isEmpty else { return }
        struct Step {
            let order: Int
            let location: FavoriteLocation
            let parent: FavoriteLocation
            let date: Date
        }
        let firstByID = Dictionary(collections.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var removedIDs: Set<String> = []
        var steps: [FavoriteLocation: Step] = [:]
        for (order, id) in collectionIDs.enumerated() {
            let date = now()
            guard let collection = firstByID[id], removedIDs.insert(id).inserted else { continue }
            let location = FavoriteLocation.collection(categoryID: collection.categoryID, collectionID: id)
            steps[location] = Step(order: order, location: location,
                                   parent: .category(collection.categoryID), date: date)
            deletedCollectionIDs[id] = date
        }
        guard !removedIDs.isEmpty else { return }
        collections.removeAll { removedIDs.contains($0.id) }
        items = items.map { original in
            var matches: [Step] = []
            var seenOrders: Set<Int> = []
            var remaining: [FavoriteLocation] = []
            for location in original.locations {
                if let step = steps[location] {
                    if seenOrders.insert(step.order).inserted { matches.append(step) }
                } else {
                    remaining.append(location)
                }
            }
            guard !matches.isEmpty else { return original }
            matches.sort { $0.order < $1.order }

            // Normalization deduplicates by location.id, not enum equality.
            // Unusual decoded IDs containing ":collection:" can make two
            // different locations collide. Replay only this affected item so
            // an earlier normalization cannot revive a suppressed parent or
            // advance a later clock for a location that no longer exists.
            var firstLocationByID: [String: FavoriteLocation] = [:]
            let hasIDCollision = (original.locations + matches.map(\.parent)).contains { location in
                if let first = firstLocationByID[location.id] { return first != location }
                firstLocationByID[location.id] = location
                return false
            }
            var item = original
            if hasIDCollision {
                for step in matches where item.locations.contains(step.location) {
                    item.locations.removeAll { $0 == step.location }
                    item.locations = FavoriteItem.normalizedLocations(item.locations + [step.parent])
                    item.locationsUpdatedAt = step.date
                    item.updatedAt = step.date
                }
            } else {
                item.locations = FavoriteItem.normalizedLocations(remaining + matches.map(\.parent))
                item.locationsUpdatedAt = matches.last!.date
                item.updatedAt = matches.last!.date
            }
            return item
        }
    }
}

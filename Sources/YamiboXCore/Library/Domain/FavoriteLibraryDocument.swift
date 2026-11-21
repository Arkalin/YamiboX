import Foundation

public struct FavoriteLibraryDocument: Codable, Equatable, Sendable {
    public var categories: [FavoriteCategory]
    public var collections: [LocalFavoriteCollection]
    public var items: [FavoriteItem]
    public var tags: [FavoriteTag]

    internal var deletedItemIDs: [String: Date]
    internal var deletedCategoryIDs: [String: Date]
    internal var deletedCollectionIDs: [String: Date]
    internal var deletedTagIDs: [String: Date]

    public init(
        categories: [FavoriteCategory] = [.defaultCategory],
        collections: [LocalFavoriteCollection] = [],
        items: [FavoriteItem] = [],
        tags: [FavoriteTag] = []
    ) {
        self.init(
            categories: categories,
            collections: collections,
            items: items,
            tags: tags,
            deletedItemIDs: [:],
            deletedCategoryIDs: [:],
            deletedCollectionIDs: [:],
            deletedTagIDs: [:]
        )
    }

    init(
        categories: [FavoriteCategory],
        collections: [LocalFavoriteCollection],
        items: [FavoriteItem],
        tags: [FavoriteTag],
        deletedItemIDs: [String: Date],
        deletedCategoryIDs: [String: Date],
        deletedCollectionIDs: [String: Date],
        deletedTagIDs: [String: Date]
    ) {
        self.categories = Self.normalizedCategories(categories)
        self.collections = collections
        self.items = Self.normalizedItems(items, categories: self.categories, collections: collections, tags: tags)
        self.tags = tags
        self.deletedItemIDs = deletedItemIDs
        self.deletedCategoryIDs = deletedCategoryIDs
        self.deletedCollectionIDs = deletedCollectionIDs
        self.deletedTagIDs = deletedTagIDs
    }

    func rebuiltPreservingTombstones() -> FavoriteLibraryDocument {
        FavoriteLibraryDocument(
            categories: categories,
            collections: collections,
            items: items,
            tags: tags,
            deletedItemIDs: deletedItemIDs,
            deletedCategoryIDs: deletedCategoryIDs,
            deletedCollectionIDs: deletedCollectionIDs,
            deletedTagIDs: deletedTagIDs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case categories, collections, items, tags
        case deletedItemIDs, deletedCategoryIDs, deletedCollectionIDs, deletedTagIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decode([FavoriteCategory].self, forKey: .categories)
        collections = try container.decode([LocalFavoriteCollection].self, forKey: .collections)
        items = try container.decode([FavoriteItem].self, forKey: .items)
        tags = try container.decode([FavoriteTag].self, forKey: .tags)
        deletedItemIDs = try container.decodeIfPresent([String: Date].self, forKey: .deletedItemIDs) ?? [:]
        deletedCategoryIDs = try container.decodeIfPresent([String: Date].self, forKey: .deletedCategoryIDs) ?? [:]
        deletedCollectionIDs = try container.decodeIfPresent([String: Date].self, forKey: .deletedCollectionIDs) ?? [:]
        deletedTagIDs = try container.decodeIfPresent([String: Date].self, forKey: .deletedTagIDs) ?? [:]
    }

    public var defaultCategory: FavoriteCategory {
        categories.first(where: \.isDefault) ?? .defaultCategory
    }

    static func normalizedCategories(_ categories: [FavoriteCategory]) -> [FavoriteCategory] {
        var result = categories
        if !result.contains(where: \.isDefault) {
            result.insert(.defaultCategory, at: 0)
        }
        if result.filter(\.isDefault).count > 1 {
            var foundDefault = false
            result = result.map { category in
                var category = category
                if category.isDefault {
                    category.isDefault = !foundDefault
                    foundDefault = true
                }
                return category
            }
        }
        result = result.map { category in
            var category = category
            if category.isDefault {
                category.name = FavoriteCategory.defaultStorageName
            }
            return category
        }
        return result.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            if lhs.manualOrder != rhs.manualOrder {
                return lhs.manualOrder < rhs.manualOrder
            }
            return lhs.id < rhs.id
        }
    }

    private static func normalizedItems(
        _ items: [FavoriteItem],
        categories: [FavoriteCategory],
        collections: [LocalFavoriteCollection],
        tags: [FavoriteTag]
    ) -> [FavoriteItem] {
        guard !items.isEmpty else { return [] }
        let index = ItemNormalizationIndex(categories: categories, collections: collections, tags: tags)
        var newestByID: [String: FavoriteItem] = [:]
        for item in items {
            let normalized = normalizedItem(item, index: index)
            if let existing = newestByID[normalized.id], existing.updatedAt >= normalized.updatedAt {
                continue
            }
            newestByID[normalized.id] = normalized
        }
        return newestByID.values.sorted { lhs, rhs in lhs.id < rhs.id }
    }

    static func normalizedItem(
        _ item: FavoriteItem,
        categories: [FavoriteCategory],
        collections: [LocalFavoriteCollection],
        tags: [FavoriteTag]
    ) -> FavoriteItem {
        normalizedItem(item, index: ItemNormalizationIndex(categories: categories, collections: collections, tags: tags))
    }

    struct ItemNormalizationIndex {
        let validCategoryIDs: Set<String>
        let validCollectionIDsByCategory: [String: Set<String>]
        let defaultCategoryID: String
        let validTagIDs: Set<String>

        init(categories: [FavoriteCategory], collections: [LocalFavoriteCollection], tags: [FavoriteTag]) {
            validCategoryIDs = Set(categories.map(\.id))
            validCollectionIDsByCategory = Dictionary(grouping: collections, by: \.categoryID)
                .mapValues { Set($0.map(\.id)) }
            defaultCategoryID = categories.first(where: \.isDefault)?.id ?? FavoriteCategory.defaultID
            validTagIDs = Set(tags.map(\.id))
        }
    }

    static func normalizedItem(_ item: FavoriteItem, index: ItemNormalizationIndex) -> FavoriteItem {
        var item = item
        let forumMetadata = FavoriteSourceGroup.normalizedForumMetadata(
            sourceGroup: item.sourceGroup,
            forumID: item.forumID,
            forumName: item.forumName
        )
        item.sourceGroup = forumMetadata.sourceGroup
        item.forumID = forumMetadata.forumID
        item.forumName = forumMetadata.forumName
        let filtered = item.locations.filter { location in
            guard index.validCategoryIDs.contains(location.categoryID) else { return false }
            guard let collectionID = location.collectionID else { return true }
            return index.validCollectionIDsByCategory[location.categoryID, default: []].contains(collectionID)
        }
        item.locations = filtered.isEmpty ? [.category(index.defaultCategoryID)] : filtered
        item.tagIDs = FavoriteItem.normalizedIDs(item.tagIDs).filter { index.validTagIDs.contains($0) }
        return item
    }
}

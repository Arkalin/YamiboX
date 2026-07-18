import Foundation

/// Stored state and construction-time normalization of the favorites
/// library document. The mutating API is split by sub-domain into
/// `FavoriteLibraryDocument+Items/+Categories/+Collections/+Tags.swift`;
/// the `normalized*` helpers stay here because `init` funnels every
/// programmatic (re)construction through them.
public struct FavoriteLibraryDocument: Codable, Equatable, Sendable {
    public var categories: [FavoriteCategory]
    public var collections: [LocalFavoriteCollection]
    public var items: [FavoriteItem]
    public var tags: [FavoriteTag]

    public init(
        categories: [FavoriteCategory] = [.defaultCategory],
        collections: [LocalFavoriteCollection] = [],
        items: [FavoriteItem] = [],
        tags: [FavoriteTag] = []
    ) {
        self.categories = Self.normalizedCategories(categories)
        self.collections = collections
        self.items = Self.normalizedItems(items, categories: self.categories, collections: collections)
        self.tags = tags
    }

    public var defaultCategory: FavoriteCategory {
        categories.first(where: \.isDefault) ?? .defaultCategory
    }

    /// Internal rather than private: the category-mutating API lives in
    /// `FavoriteLibraryDocument+Categories.swift` and must re-normalize
    /// after every change, while `init` also funnels through here.
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
        collections: [LocalFavoriteCollection]
    ) -> [FavoriteItem] {
        // Deduplicate by target id, keeping the most recently updated entry.
        // Codable decoding bypasses this initializer, but every programmatic
        // (re)construction runs through here, so sync payloads routed through
        // the initializer cannot re-introduce duplicate targets.
        var newestByID: [String: FavoriteItem] = [:]
        for item in items {
            let normalized = normalizedItem(item, categories: categories, collections: collections)
            if let existing = newestByID[normalized.id], existing.updatedAt >= normalized.updatedAt {
                continue
            }
            newestByID[normalized.id] = normalized
        }
        return newestByID.values.sorted { lhs, rhs in lhs.id < rhs.id }
    }

    /// Internal rather than private: every item write path in
    /// `FavoriteLibraryDocument+Items.swift` must funnel through this
    /// normalization, and `normalizedItems` above reuses it for `init`.
    static func normalizedItem(
        _ item: FavoriteItem,
        categories: [FavoriteCategory],
        collections: [LocalFavoriteCollection]
    ) -> FavoriteItem {
        var item = item
        let forumMetadata = FavoriteSourceGroup.normalizedForumMetadata(
            sourceGroup: item.sourceGroup,
            forumID: item.forumID,
            forumName: item.forumName
        )
        item.sourceGroup = forumMetadata.sourceGroup
        item.forumID = forumMetadata.forumID
        item.forumName = forumMetadata.forumName
        let validCategoryIDs = Set(categories.map(\.id))
        let validCollectionIDsByCategory = Dictionary(grouping: collections, by: \.categoryID)
            .mapValues { Set($0.map(\.id)) }
        let filtered = item.locations.filter { location in
            guard validCategoryIDs.contains(location.categoryID) else { return false }
            guard let collectionID = location.collectionID else { return true }
            return validCollectionIDsByCategory[location.categoryID, default: []].contains(collectionID)
        }
        item.locations = filtered.isEmpty ? [.category(categories.first(where: \.isDefault)?.id ?? FavoriteCategory.defaultID)] : filtered
        item.tagIDs = FavoriteItem.normalizedIDs(item.tagIDs)
        return item
    }
}

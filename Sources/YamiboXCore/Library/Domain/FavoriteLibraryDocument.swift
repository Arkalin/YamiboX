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

    /// id → deletedAt for items/categories/collections/tags removed from
    /// this document. Consulted only by `FavoriteLibraryWebDAVMerger` so a
    /// deletion isn't silently revived by a stale peer's union-by-id copy of
    /// the same id — see each deletion call site
    /// (`removeItem`/`deleteCategory`/`dissolveCollection`/`deleteTag`) for
    /// where these are written. `deletedItemIDs` is timestamped because
    /// `FavoriteItemTarget.id` is content-derived (re-favoriting the same
    /// thread reuses it), so a later re-add must be able to outrun an older
    /// tombstone; the other three key on randomly generated ids that are
    /// never reused, so once tombstoned they stay tombstoned permanently —
    /// the date is kept anyway for uniform merge-time handling and for
    /// debugging, not because reconciliation ever reads it.
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

    /// Internal counterpart used by `FavoriteLibraryWebDAVMerger` (to carry
    /// merged tombstones into `mergedLibrary`) and `FavoriteLibraryStore`'s
    /// `canonicalized()` (to keep tombstones from being silently reset on
    /// every save) — the public initializer above always starts a document
    /// with no tombstones, which is correct for every external construction
    /// site but would be wrong for those two, since both are reconstructing
    /// a document that may already carry real ones.
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

    /// Rebuilds this document through the normalizing initializer (see
    /// `normalizedCategories`/`normalizedItems`) while carrying its own
    /// deletion tombstones forward — for callers that need to re-run
    /// normalization on a document that may already carry live tombstones
    /// (`FavoriteLibraryWebDAVParticipant.applyRemote`,
    /// `FavoriteLibraryStore.canonicalized`), where the public initializer's
    /// implicit "start with no tombstones" would silently erase them.
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

    /// Hand-written rather than synthesized so old persisted documents
    /// (written before these tombstone fields existed) keep decoding — see
    /// `FavoriteLibraryWebDAVPayload.currentVersion`'s doc comment for the
    /// same tolerance precedent. Deliberately does NOT route through the
    /// normalizing initializer above, matching the prior synthesized
    /// decode's behavior: `normalizedItems`'s doc comment already documents
    /// that "Codable decoding bypasses this initializer" as load-bearing
    /// (every deliberate (re)construction call site normalizes explicitly;
    /// blind normalization on every decode is not something existing code
    /// expects).
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
        collections: [LocalFavoriteCollection],
        tags: [FavoriteTag]
    ) -> [FavoriteItem] {
        // Deduplicate by target id, keeping the most recently updated entry.
        // Codable decoding bypasses this initializer, but every programmatic
        // (re)construction runs through here, so sync payloads routed through
        // the initializer cannot re-introduce duplicate targets.
        var newestByID: [String: FavoriteItem] = [:]
        for item in items {
            let normalized = normalizedItem(item, categories: categories, collections: collections, tags: tags)
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
        collections: [LocalFavoriteCollection],
        tags: [FavoriteTag]
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
        // Cross-validated against `tags`, not just deduplicated, mirroring
        // `locations`'s validity filter above: a tag deleted (and tombstoned)
        // on one device can still win the `tagIDs` last-writer-wins merge on
        // an item from a peer that never learned about the deletion — without
        // this filter, the now-nonexistent tag id would persist as a dangling
        // reference on that item forever (invisible in the UI, but sitting in
        // the data) instead of being dropped like a dangling location is.
        let validTagIDs = Set(tags.map(\.id))
        item.tagIDs = FavoriteItem.normalizedIDs(item.tagIDs).filter { validTagIDs.contains($0) }
        return item
    }
}

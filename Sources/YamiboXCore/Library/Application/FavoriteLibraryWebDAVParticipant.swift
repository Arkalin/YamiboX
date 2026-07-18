import CryptoKit
import Foundation

/// WebDAV sync participant for the local favorite library. Owns the payload
/// format and CRDT-style merge semantics for favorites.
struct FavoriteLibraryWebDAVParticipant: WebDAVSyncParticipant {
    let datasetID = "favoriteLibrary"
    let remoteFileName = "yamibox-favorite-library-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let store: FavoriteLibraryStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: FavoriteLibraryStore) {
        self.store = store
    }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try decoder.decode(FavoriteLibraryWebDAVPayload.self, from: data)
        return WebDAVRemotePayloadInfo(
            updatedAt: payload.updatedAt,
            accountUID: payload.accountUID,
            revision: payload.syncRevision
        )
    }

    func mergeAndExport(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> Data {
        let remote = try remoteData.map { try decoder.decode(FavoriteLibraryWebDAVPayload.self, from: $0) }
        // Atomic update: merging against the same document state that gets
        // overwritten, so local edits landing mid-merge are never lost.
        let merged = try await store.update { document in
            let local = FavoriteLibraryWebDAVPayload(
                updatedAt: updatedAt,
                accountUID: accountUID,
                library: document
            )
            let merged = FavoriteLibraryWebDAVMerger().merge(local: local, remote: remote, updatedAt: updatedAt)
            document = merged.library
            return merged
        }
        return try encoder.encode(merged)
    }

    func applyRemote(_ data: Data) async throws {
        let payload = try decoder.decode(FavoriteLibraryWebDAVPayload.self, from: data)
        // Codable decoding bypasses `FavoriteLibraryDocument`'s normalizing
        // initializer; rebuild through it so a malformed remote payload
        // (duplicate target ids, dangling locations) cannot persist invariant
        // violations into the local store. Carries the remote's own deletion
        // tombstones through too (not the public 4-param initializer, which
        // would silently reset them) — this device is adopting the remote's
        // full history here, and dropping its tombstones would let a still-
        // stale third peer revive something the remote already knows is gone.
        try await store.save(payload.library.rebuiltPreservingTombstones())
    }

    // Hashed rather than base64-of-full-JSON (unlike AppSettingsWebDAVParticipant):
    // a favorite library can grow large, and the fingerprint is persisted inside
    // the (already UserDefaults-backed) WebDAVSyncSettings blob. Fingerprints the
    // locally stored document — including its deletion tombstones and each
    // item's per-field clocks, both genuinely local state now (see
    // `FavoriteLibraryDocument`'s and `FavoriteItem`'s doc comments).
    func localFingerprint() async -> String? {
        let document: FavoriteLibraryDocument
        do {
            document = try await store.load()
        } catch {
            YamiboLog.sync.warning("Failed to load favorite library for WebDAV fingerprint: \(error)")
            return nil
        }
        let fingerprintEncoder = JSONEncoder()
        fingerprintEncoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try fingerprintEncoder.encode(document)
        } catch {
            YamiboLog.sync.warning("Failed to encode favorite library fingerprint for WebDAV sync: \(error)")
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct FavoriteLibraryWebDAVPayload: Codable, Equatable, Sendable {
    // Still v2 after FavoriteItem dropped coverURL (covers moved to the
    // content_cover table), after deletion tombstones moved from a separate
    // `FavoriteLibraryWebDAVTombstones` wrapper field (which never had
    // anything writing to it) into `library` itself, and after this same
    // envelope's `clocks` field was dropped once `FavoriteItem` grew its own
    // per-field `locationsUpdatedAt`/`tagIDsUpdatedAt`/`displayNameUpdatedAt`/
    // `remoteMappingUpdatedAt` (see `FavoriteItem`'s doc comment — the old
    // `FavoriteLibraryWebDAVClocks` had the identical "never actually
    // written from local state" flaw as the old tombstones field): decoding
    // tolerates the removed keys and the app is pre-release, so no format
    // break is needed.
    static let currentVersion = 2

    var version: Int
    var updatedAt: Date
    var accountUID: String?
    /// Monotonic per-dataset sync revision, stamped into the envelope by the
    /// sync service after export; nil for payloads written before revisions
    /// existed (decode falls back to `updatedAt` comparisons then).
    var syncRevision: UInt64?
    var library: FavoriteLibraryDocument

    init(
        version: Int = Self.currentVersion,
        updatedAt: Date,
        accountUID: String? = nil,
        syncRevision: UInt64? = nil,
        library: FavoriteLibraryDocument
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.accountUID = accountUID
        self.syncRevision = syncRevision
        self.library = library
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case accountUID
        case syncRevision
        case library
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(Int.self, forKey: .version) else {
            throw WebDAVSyncError.unsupportedPayloadVersion(0)
        }
        guard version == Self.currentVersion else {
            throw WebDAVSyncError.unsupportedPayloadVersion(version)
        }
        self.version = version
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.accountUID = try container.decodeIfPresent(String.self, forKey: .accountUID)
        self.syncRevision = try container.decodeIfPresent(UInt64.self, forKey: .syncRevision)
        self.library = try container.decode(FavoriteLibraryDocument.self, forKey: .library)
    }
}

struct FavoriteLibraryWebDAVMerger: Sendable {
    init() {}

    func merge(
        local: FavoriteLibraryWebDAVPayload,
        remote: FavoriteLibraryWebDAVPayload?,
        updatedAt: Date
    ) -> FavoriteLibraryWebDAVPayload {
        guard let remote else {
            var upload = local
            upload.version = FavoriteLibraryWebDAVPayload.currentVersion
            upload.updatedAt = updatedAt
            return upload
        }

        let (categories, deletedCategoryIDs) = mergeCategories(local: local.library, remote: remote.library)
        let (collections, deletedCollectionIDs) = mergeCollections(
            local: local.library,
            remote: remote.library,
            validCategoryIDs: Set(categories.map(\.id))
        )
        let (tags, deletedTagIDs) = mergeTags(local: local.library, remote: remote.library)
        let (items, deletedItemIDs) = mergeItems(local: local.library, remote: remote.library)
        // Internal 8-param initializer, not the public one: the public one
        // always starts a document with no tombstones, which would silently
        // drop every one of the three sides' deletions computed just above.
        let mergedLibrary = FavoriteLibraryDocument(
            categories: categories,
            collections: collections,
            items: items,
            tags: tags,
            deletedItemIDs: deletedItemIDs,
            deletedCategoryIDs: deletedCategoryIDs,
            deletedCollectionIDs: deletedCollectionIDs,
            deletedTagIDs: deletedTagIDs
        )

        return FavoriteLibraryWebDAVPayload(
            version: FavoriteLibraryWebDAVPayload.currentVersion,
            updatedAt: updatedAt,
            accountUID: local.accountUID ?? remote.accountUID,
            library: mergedLibrary
        )
    }

    private func mergeItems(
        local: FavoriteLibraryDocument,
        remote: FavoriteLibraryDocument
    ) -> (items: [FavoriteItem], deletedItemIDs: [String: Date]) {
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: Codable
        // decoding bypasses the document initializer's normalization, so a
        // payload written by an older/buggy peer (or edited by hand) can
        // carry duplicate target ids — that must degrade to keep-newest, not
        // crash every future sync round.
        let localByID = Dictionary(local.items.map { ($0.id, $0) }, uniquingKeysWith: Self.newerItem)
        let remoteByID = Dictionary(remote.items.map { ($0.id, $0) }, uniquingKeysWith: Self.newerItem)
        var deletedItemIDs = maxDateDictionary(local.deletedItemIDs, remote.deletedItemIDs)

        let items = Set(localByID.keys).union(remoteByID.keys).compactMap { targetID -> FavoriteItem? in
            guard var item = localByID[targetID] ?? remoteByID[targetID] else { return nil }
            if let remoteItem = remoteByID[targetID], localByID[targetID] == nil {
                item = remoteItem
            } else if let localItem = localByID[targetID], let remoteItem = remoteByID[targetID] {
                // Each of these four fields merges independently by its own
                // dedicated clock, not a shared decision keyed off the
                // item's overall `updatedAt` — otherwise a device that
                // legitimately only edited (say) `tagIDs` could have that
                // edit silently overwritten by a peer whose only, unrelated,
                // but chronologically later edit touched `locations`, and
                // vice versa. This is last-writer-wins, not a union: a value
                // removed on one device (e.g. moving a favorite out of a
                // category) must actually disappear from the merged result,
                // not get re-added by the other side's stale copy — see the
                // git history for why a naive union-plus-tombstone design
                // (where the tombstone was never actually written) silently
                // undid every such removal on the very next sync round.
                // Ties favor local, mirroring `newerItem`'s tie-breaking.
                item.locations = localItem.locationsUpdatedAt >= remoteItem.locationsUpdatedAt ? localItem.locations : remoteItem.locations
                item.locationsUpdatedAt = max(localItem.locationsUpdatedAt, remoteItem.locationsUpdatedAt)
                item.tagIDs = localItem.tagIDsUpdatedAt >= remoteItem.tagIDsUpdatedAt ? localItem.tagIDs : remoteItem.tagIDs
                item.tagIDsUpdatedAt = max(localItem.tagIDsUpdatedAt, remoteItem.tagIDsUpdatedAt)
                item.displayName = localItem.displayNameUpdatedAt >= remoteItem.displayNameUpdatedAt ? localItem.displayName : remoteItem.displayName
                item.displayNameUpdatedAt = max(localItem.displayNameUpdatedAt, remoteItem.displayNameUpdatedAt)
                item.remoteMapping = localItem.remoteMappingUpdatedAt >= remoteItem.remoteMappingUpdatedAt ? localItem.remoteMapping : remoteItem.remoteMapping
                item.remoteMappingUpdatedAt = max(localItem.remoteMappingUpdatedAt, remoteItem.remoteMappingUpdatedAt)
                item.contentUpdatedAt = maxDate(localItem.contentUpdatedAt, remoteItem.contentUpdatedAt)
                item.forumID = localItem.forumID ?? remoteItem.forumID
                item.forumName = localItem.forumName ?? remoteItem.forumName
                item.updatedAt = max(localItem.updatedAt, remoteItem.updatedAt)
            }
            if let deletedAt = deletedItemIDs[targetID] {
                // `>=`, not `>`: every other tie-break in this merger favors
                // survival/local on an exact timestamp match (`newerItem`,
                // each per-field clock comparison above), so a resurrection
                // racing its own tombstone to the same instant should
                // resolve the same way.
                guard item.updatedAt >= deletedAt else { return nil }
                // Resurrected after the deletion (the same thread was
                // favorited again — `FavoriteItemTarget.id` is content-
                // derived, so it reuses the old id): the tombstone no longer
                // applies and must not keep suppressing this id forever.
                deletedItemIDs.removeValue(forKey: targetID)
            }
            return item.locations.isEmpty ? nil : item
        }
        .sorted { $0.id < $1.id }

        return (items, deletedItemIDs)
    }

    private static func newerItem(_ lhs: FavoriteItem, _ rhs: FavoriteItem) -> FavoriteItem {
        lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    // Category/collection/tag ids are random UUIDs that are never reused
    // (unlike an item's content-derived target id), so once tombstoned an id
    // is excluded permanently — no resurrection reconciliation needed.

    private func mergeCategories(
        local: FavoriteLibraryDocument,
        remote: FavoriteLibraryDocument
    ) -> (categories: [FavoriteCategory], deletedIDs: [String: Date]) {
        let deletedIDs = maxDateDictionary(local.deletedCategoryIDs, remote.deletedCategoryIDs)
        let categories = keyedByID(local.categories + remote.categories)
            .filter { deletedIDs[$0.id] == nil }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            }
        return (categories, deletedIDs)
    }

    private func mergeCollections(
        local: FavoriteLibraryDocument,
        remote: FavoriteLibraryDocument,
        validCategoryIDs: Set<String>
    ) -> (collections: [LocalFavoriteCollection], deletedIDs: [String: Date]) {
        let deletedIDs = maxDateDictionary(local.deletedCollectionIDs, remote.deletedCollectionIDs)
        let collections = keyedByID(local.collections + remote.collections)
            // `deleteCategory` only cascade-tombstones the collections it
            // knows about; a collection a peer created (under the same
            // category) concurrently with — but never synced before — that
            // deletion has no tombstone of its own. Falling back to "its
            // category still exists post-merge" catches that case too,
            // mirroring `normalizedItem`'s location-validity filter.
            .filter { deletedIDs[$0.id] == nil && validCategoryIDs.contains($0.categoryID) }
            .sorted {
                if $0.categoryID != $1.categoryID { return $0.categoryID < $1.categoryID }
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            }
        return (collections, deletedIDs)
    }

    private func mergeTags(
        local: FavoriteLibraryDocument,
        remote: FavoriteLibraryDocument
    ) -> (tags: [FavoriteTag], deletedIDs: [String: Date]) {
        let deletedIDs = maxDateDictionary(local.deletedTagIDs, remote.deletedTagIDs)
        let tags = keyedByID(local.tags + remote.tags)
            .filter { deletedIDs[$0.id] == nil }
            .sorted {
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            }
        return (tags, deletedIDs)
    }
}

private func maxDateDictionary(_ lhs: [String: Date], _ rhs: [String: Date]) -> [String: Date] {
    var result = lhs
    for (key, value) in rhs {
        if let existing = result[key], existing >= value {
            continue
        }
        result[key] = value
    }
    return result
}

private func keyedByID<Value: Identifiable>(_ values: [Value]) -> [Value] where Value.ID == String {
    var byID: [String: Value] = [:]
    for value in values {
        byID[value.id] = value
    }
    return Array(byID.values)
}

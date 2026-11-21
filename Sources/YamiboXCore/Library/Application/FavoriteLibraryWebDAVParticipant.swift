import CryptoKit
import Foundation

struct FavoriteLibraryWebDAVParticipant: MangaIdentitySyncParticipant {
    var mangaIdentityStrategy: MangaIdentityPayloadStrategy? {
        MangaIdentityPayloadStrategy(normalizePayload: FavoriteLibraryWebDAVPayload.normalizingMangaIdentities)
    }

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

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> WebDAVExportSnapshot {
        let remote = try remoteData.map { try decoder.decode(FavoriteLibraryWebDAVPayload.self, from: $0) }
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
        return WebDAVExportSnapshot(data: try encoder.encode(merged), fingerprint: try WebDAVSyncFingerprint.make(merged.library))
    }

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot {
        let payload = try decoder.decode(FavoriteLibraryWebDAVPayload.self, from: data)
        let result = try await mergeAndExportSnapshot(remoteData: data, updatedAt: payload.updatedAt,
            accountUID: payload.accountUID ?? "")
        return WebDAVApplySnapshot(fingerprint: result.fingerprint,
            requiresUpload: result.fingerprint != (try WebDAVSyncFingerprint.make(payload.library.rebuiltPreservingTombstones())))
    }

    func readLocalFingerprint() async throws -> String? {
        try WebDAVSyncFingerprint.make(await store.load())
    }
}

struct FavoriteLibraryWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var updatedAt: Date
    var accountUID: String?
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
        let localByID = Dictionary(local.items.map { ($0.id, $0) }, uniquingKeysWith: Self.newerItem)
        let remoteByID = Dictionary(remote.items.map { ($0.id, $0) }, uniquingKeysWith: Self.newerItem)
        var deletedItemIDs = SyncDeletionState.mergingTombstones(local.deletedItemIDs, remote.deletedItemIDs)

        let items = Set(localByID.keys).union(remoteByID.keys).compactMap { targetID -> FavoriteItem? in
            guard var item = localByID[targetID] ?? remoteByID[targetID] else { return nil }
            if let remoteItem = remoteByID[targetID], localByID[targetID] == nil {
                item = remoteItem
            } else if let localItem = localByID[targetID], let remoteItem = remoteByID[targetID] {
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
                guard item.updatedAt >= deletedAt else { return nil }
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

    private func mergeCategories(
        local: FavoriteLibraryDocument,
        remote: FavoriteLibraryDocument
    ) -> (categories: [FavoriteCategory], deletedIDs: [String: Date]) {
        let deletedIDs = SyncDeletionState.mergingTombstones(local.deletedCategoryIDs, remote.deletedCategoryIDs)
        let categories = newestByID(
            local: local.categories,
            remote: remote.categories,
            updatedAt: \.updatedAt
        )
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
        let deletedIDs = SyncDeletionState.mergingTombstones(local.deletedCollectionIDs, remote.deletedCollectionIDs)
        let collections = newestByID(
            local: local.collections,
            remote: remote.collections,
            updatedAt: \.updatedAt
        )
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
        let deletedIDs = SyncDeletionState.mergingTombstones(local.deletedTagIDs, remote.deletedTagIDs)
        let tags = newestByID(
            local: local.tags,
            remote: remote.tags,
            updatedAt: \.updatedAt
        )
            .filter { deletedIDs[$0.id] == nil }
            .sorted {
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            }
        return (tags, deletedIDs)
    }
}

private func newestByID<Value: Identifiable>(
    local: [Value],
    remote: [Value],
    updatedAt: (Value) -> Date
) -> [Value] where Value.ID == String {
    let newest: (Value, Value) -> Value = { lhs, rhs in
        updatedAt(lhs) >= updatedAt(rhs) ? lhs : rhs
    }
    var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: newest)
    let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: newest)
    for (id, remoteValue) in remoteByID {
        guard let localValue = byID[id] else {
            byID[id] = remoteValue
            continue
        }
        if updatedAt(remoteValue) > updatedAt(localValue) {
            byID[id] = remoteValue
        }
    }
    return Array(byID.values)
}

private extension FavoriteLibraryWebDAVPayload {
    static func normalizingMangaIdentities(_ data: Data, _ identities: MangaDirectoryIdentitySnapshot, _: [Int: MangaIdentityLegacyTarget]) throws -> Data {
        var payload = try JSONDecoder().decode(Self.self, from: data)
        payload.library = FavoriteLibraryIdentityRemapping.normalize(payload.library, identities: identities, legacy: false)
        return try JSONEncoder().encode(payload)
    }
}

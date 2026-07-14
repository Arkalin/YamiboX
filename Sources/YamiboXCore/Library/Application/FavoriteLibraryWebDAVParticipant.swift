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
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, accountUID: payload.accountUID)
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
        try await store.save(payload.library)
    }

    // Hashed rather than base64-of-full-JSON (unlike AppSettingsWebDAVParticipant):
    // a favorite library can grow large, and the fingerprint is persisted inside
    // the (already UserDefaults-backed) WebDAVSyncSettings blob. Fingerprints the
    // locally stored document only (categories/collections/items/tags) — the
    // upload's tombstones/clocks are sync bookkeeping derived at merge time, not
    // local state this participant tracks between syncs.
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
    // content_cover table): decoding tolerates the removed keys and the app
    // is pre-release, so no format break is needed.
    static let currentVersion = 2

    var version: Int
    var updatedAt: Date
    var accountUID: String?
    var library: FavoriteLibraryDocument
    var tombstones: FavoriteLibraryWebDAVTombstones
    var clocks: FavoriteLibraryWebDAVClocks

    init(
        version: Int = Self.currentVersion,
        updatedAt: Date,
        accountUID: String? = nil,
        library: FavoriteLibraryDocument,
        tombstones: FavoriteLibraryWebDAVTombstones = FavoriteLibraryWebDAVTombstones(),
        clocks: FavoriteLibraryWebDAVClocks = FavoriteLibraryWebDAVClocks()
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.accountUID = accountUID
        self.library = library
        self.tombstones = tombstones
        self.clocks = clocks
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case accountUID
        case library
        case tombstones
        case clocks
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
        self.library = try container.decode(FavoriteLibraryDocument.self, forKey: .library)
        self.tombstones = try container.decodeIfPresent(FavoriteLibraryWebDAVTombstones.self, forKey: .tombstones) ?? FavoriteLibraryWebDAVTombstones()
        self.clocks = try container.decodeIfPresent(FavoriteLibraryWebDAVClocks.self, forKey: .clocks) ?? FavoriteLibraryWebDAVClocks()
    }
}

struct FavoriteLibraryWebDAVTombstones: Codable, Equatable, Sendable {
    var removedLocationsByTargetID: [String: Set<FavoriteLocation>]
    var removedTagIDsByTargetID: [String: Set<String>]

    init(
        removedLocationsByTargetID: [String: Set<FavoriteLocation>] = [:],
        removedTagIDsByTargetID: [String: Set<String>] = [:]
    ) {
        self.removedLocationsByTargetID = removedLocationsByTargetID
        self.removedTagIDsByTargetID = removedTagIDsByTargetID
    }
}

struct FavoriteLibraryWebDAVClocks: Codable, Equatable, Sendable {
    var displayNameUpdatedAtByTargetID: [String: Date]
    var remoteMappingUpdatedAtByTargetID: [String: Date]

    init(
        displayNameUpdatedAtByTargetID: [String: Date] = [:],
        remoteMappingUpdatedAtByTargetID: [String: Date] = [:]
    ) {
        self.displayNameUpdatedAtByTargetID = displayNameUpdatedAtByTargetID
        self.remoteMappingUpdatedAtByTargetID = remoteMappingUpdatedAtByTargetID
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

        let tombstones = FavoriteLibraryWebDAVTombstones(
            removedLocationsByTargetID: unionSetDictionary(local.tombstones.removedLocationsByTargetID, remote.tombstones.removedLocationsByTargetID),
            removedTagIDsByTargetID: unionSetDictionary(local.tombstones.removedTagIDsByTargetID, remote.tombstones.removedTagIDsByTargetID)
        )
        let clocks = FavoriteLibraryWebDAVClocks(
            displayNameUpdatedAtByTargetID: maxDateDictionary(local.clocks.displayNameUpdatedAtByTargetID, remote.clocks.displayNameUpdatedAtByTargetID),
            remoteMappingUpdatedAtByTargetID: maxDateDictionary(local.clocks.remoteMappingUpdatedAtByTargetID, remote.clocks.remoteMappingUpdatedAtByTargetID)
        )
        let mergedItems = mergeItems(local: local, remote: remote, tombstones: tombstones, clocks: clocks)
        let mergedLibrary = FavoriteLibraryDocument(
            categories: mergeCategories(local.library.categories, remote.library.categories),
            collections: mergeCollections(local.library.collections, remote.library.collections),
            items: mergedItems,
            tags: mergeTags(local.library.tags, remote.library.tags)
        )

        return FavoriteLibraryWebDAVPayload(
            version: FavoriteLibraryWebDAVPayload.currentVersion,
            updatedAt: updatedAt,
            accountUID: local.accountUID ?? remote.accountUID,
            library: mergedLibrary,
            tombstones: tombstones,
            clocks: clocks
        )
    }

    private func mergeItems(
        local: FavoriteLibraryWebDAVPayload,
        remote: FavoriteLibraryWebDAVPayload,
        tombstones: FavoriteLibraryWebDAVTombstones,
        clocks: FavoriteLibraryWebDAVClocks
    ) -> [FavoriteItem] {
        let localByID = Dictionary(uniqueKeysWithValues: local.library.items.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.library.items.map { ($0.id, $0) })
        return Set(localByID.keys).union(remoteByID.keys).compactMap { targetID in
            guard var item = localByID[targetID] ?? remoteByID[targetID] else { return nil }
            if let remoteItem = remoteByID[targetID], localByID[targetID] == nil {
                item = remoteItem
            } else if let localItem = localByID[targetID], let remoteItem = remoteByID[targetID] {
                item.locations = Array(
                    Set(localItem.locations)
                        .union(remoteItem.locations)
                        .subtracting(tombstones.removedLocationsByTargetID[targetID, default: []])
                )
                item.tagIDs = Array(
                    Set(localItem.tagIDs)
                        .union(remoteItem.tagIDs)
                        .subtracting(tombstones.removedTagIDsByTargetID[targetID, default: []])
                ).sorted()
                item.displayName = choose(
                    local: localItem.displayName,
                    remote: remoteItem.displayName,
                    localDate: local.clocks.displayNameUpdatedAtByTargetID[targetID],
                    remoteDate: remote.clocks.displayNameUpdatedAtByTargetID[targetID]
                )
                item.contentUpdatedAt = maxDate(localItem.contentUpdatedAt, remoteItem.contentUpdatedAt)
                item.forumID = localItem.forumID ?? remoteItem.forumID
                item.forumName = localItem.forumName ?? remoteItem.forumName
                item.remoteMapping = choose(
                    local: localItem.remoteMapping,
                    remote: remoteItem.remoteMapping,
                    localDate: local.clocks.remoteMappingUpdatedAtByTargetID[targetID],
                    remoteDate: remote.clocks.remoteMappingUpdatedAtByTargetID[targetID]
                )
                item.updatedAt = max(localItem.updatedAt, remoteItem.updatedAt)
            }
            return item.locations.isEmpty ? nil : item
        }
        .sorted { $0.id < $1.id }
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

    private func mergeCategories(_ local: [FavoriteCategory], _ remote: [FavoriteCategory]) -> [FavoriteCategory] {
        keyedByID(local + remote)
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            }
    }

    private func mergeCollections(_ local: [LocalFavoriteCollection], _ remote: [LocalFavoriteCollection]) -> [LocalFavoriteCollection] {
        keyedByID(local + remote)
            .sorted {
                if $0.categoryID != $1.categoryID { return $0.categoryID < $1.categoryID }
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            }
    }

    private func mergeTags(_ local: [FavoriteTag], _ remote: [FavoriteTag]) -> [FavoriteTag] {
        keyedByID(local + remote)
            .sorted {
                if $0.manualOrder != $1.manualOrder { return $0.manualOrder < $1.manualOrder }
                return $0.id < $1.id
            }
    }
}

private func unionSetDictionary<Value: Hashable>(
    _ lhs: [String: Set<Value>],
    _ rhs: [String: Set<Value>]
) -> [String: Set<Value>] {
    var result = lhs
    for (key, values) in rhs {
        result[key, default: []].formUnion(values)
    }
    return result
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

private func choose<Value>(
    local: Value?,
    remote: Value?,
    localDate: Date?,
    remoteDate: Date?
) -> Value? {
    guard localDate != remoteDate else { return local ?? remote }
    if let remoteDate, localDate == nil || remoteDate > localDate! {
        return remote
    }
    return local
}

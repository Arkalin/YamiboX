import CryptoKit
import Foundation

/// WebDAV sync participant for the Like Library. Like Items are effectively
/// immutable once created (only "exists" -> "deleted" transitions happen), so
/// this uses newest-record-wins-by-id merge semantics, same as
/// `ReadingProgressWebDAVParticipant`, plus a tombstone set so a stale remote
/// snapshot can't resurrect a locally deleted item. Image bytes never travel
/// in this payload (ADR-0049): only `LikeItem` metadata, which already has no
/// local-file field to strip (`LikeImageStore` resolves bytes purely by
/// `LikeItem.id`, so other devices re-fetch via `sourceImageURL` through the
/// existing `LikeWorkItemsView` fallback, no new code needed here).
struct LikeLibraryWebDAVParticipant: WebDAVSyncParticipant {
    let datasetID = "likeLibrary"
    let remoteFileName = "yamibox-like-library-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let store: LikeStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: LikeStore) {
        self.store = store
    }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try decoder.decode(LikeLibraryWebDAVPayload.self, from: data)
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, revision: payload.syncRevision)
    }

    func mergeAndExport(remoteData: Data?, updatedAt: Date, accountUID _: String) async throws -> Data {
        let localSnapshot = await store.allIncludingDeleted()
        let remote = try remoteData.map { try decoder.decode(LikeLibraryWebDAVPayload.self, from: $0) }
        let outcome = LikeLibraryWebDAVMerger().merge(localSnapshot: localSnapshot, remote: remote, updatedAt: updatedAt)
        try await store.replaceAll(outcome.storageSnapshot)
        return try encoder.encode(outcome.payload)
    }

    func applyRemote(_ data: Data) async throws {
        let payload = try decoder.decode(LikeLibraryWebDAVPayload.self, from: data)
        // A straight overwrite has nothing local left to protect against
        // revival, so bare tombstones (no known item data) don't need to be
        // materialized as placeholder rows here.
        try await store.replaceAll(payload.items)
    }

    // Hashed rather than base64-of-full-JSON (unlike AppSettingsWebDAVParticipant):
    // this dataset can grow large, and the fingerprint is persisted inside the
    // (already UserDefaults-backed) WebDAVSyncSettings blob. Includes deleted rows
    // (matching mergeAndExport's synced subset) so a delete alone still marks dirty.
    func localFingerprint() async -> String? {
        let snapshot = await store.allIncludingDeleted()
        let fingerprintEncoder = JSONEncoder()
        fingerprintEncoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try fingerprintEncoder.encode(snapshot)
        } catch {
            YamiboLog.sync.warning("Failed to encode like library fingerprint for WebDAV sync: \(error)")
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct LikeLibraryWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var updatedAt: Date
    /// Monotonic per-dataset sync revision, stamped into the envelope by the
    /// sync service after export; nil for payloads written before revisions
    /// existed (decode falls back to `updatedAt` comparisons then).
    var syncRevision: UInt64?
    var items: [LikeItem]
    /// itemID -> deletedAt. Bare by design: deleted content has nothing left
    /// worth syncing, only the fact and time of deletion.
    var tombstones: [String: Date]

    init(version: Int = Self.currentVersion, updatedAt: Date, syncRevision: UInt64? = nil, items: [LikeItem], tombstones: [String: Date]) {
        self.version = version
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
        self.items = items
        self.tombstones = tombstones
    }

    /// Builds the export payload from the full local snapshot (including
    /// soft-deleted rows): live items are exported with their data;
    /// soft-deleted rows are reduced to a bare tombstone.
    init(updatedAt: Date, localSnapshot: [LikeItem]) {
        self.version = Self.currentVersion
        self.updatedAt = updatedAt
        self.syncRevision = nil
        self.items = localSnapshot.filter { $0.deletedAt == nil }
        self.tombstones = Dictionary(uniqueKeysWithValues: localSnapshot.compactMap { item in
            item.deletedAt.map { (item.id, $0) }
        })
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case syncRevision
        case items
        case tombstones
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
        self.syncRevision = try container.decodeIfPresent(UInt64.self, forKey: .syncRevision)
        self.items = try container.decode([LikeItem].self, forKey: .items)
        self.tombstones = try container.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(syncRevision, forKey: .syncRevision)
        try container.encode(items, forKey: .items)
        try container.encode(tombstones, forKey: .tombstones)
    }
}

struct LikeLibraryWebDAVMerger: Sendable {
    struct MergeOutcome {
        var storageSnapshot: [LikeItem]
        var payload: LikeLibraryWebDAVPayload
    }

    init() {}

    func merge(localSnapshot: [LikeItem], remote: LikeLibraryWebDAVPayload?, updatedAt: Date) -> MergeOutcome {
        guard let remote else {
            let payload = LikeLibraryWebDAVPayload(updatedAt: updatedAt, localSnapshot: localSnapshot)
            return MergeOutcome(storageSnapshot: localSnapshot, payload: payload)
        }

        var byID = Dictionary(uniqueKeysWithValues: localSnapshot.map { ($0.id, $0) })
        for remoteItem in remote.items {
            if let existing = byID[remoteItem.id], existing.updatedAt >= remoteItem.updatedAt {
                continue
            }
            byID[remoteItem.id] = remoteItem
        }

        let localTombstones = Dictionary(uniqueKeysWithValues: localSnapshot.compactMap { item in
            item.deletedAt.map { (item.id, $0) }
        })
        let mergedTombstones = maxDateDictionary(localTombstones, remote.tombstones)

        // Tombstones only cover ids we still have some data for (from either
        // side's live snapshot); a bare tombstone with no known item data has
        // nothing to write a row for, but still rides along in `mergedTombstones`
        // below so this device keeps forwarding it on its next export.
        let storageSnapshot: [LikeItem] = byID.values.map { item in
            var resolved = item
            if let deletedAt = mergedTombstones[item.id], deletedAt >= item.updatedAt {
                resolved.deletedAt = deletedAt
                resolved.updatedAt = max(item.updatedAt, deletedAt)
            } else {
                resolved.deletedAt = nil
            }
            return resolved
        }

        let payload = LikeLibraryWebDAVPayload(
            updatedAt: updatedAt,
            items: storageSnapshot.filter { $0.deletedAt == nil },
            tombstones: mergedTombstones
        )
        return MergeOutcome(storageSnapshot: storageSnapshot, payload: payload)
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

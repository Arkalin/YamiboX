import CryptoKit
import Foundation

/// WebDAV sync participant for content covers. Owns the payload format and
/// newest-row-wins merge semantics for `content_cover` rows.
///
/// Covers live outside `FavoriteLibraryDocument` (in the `content_cover`
/// table), so before this participant existed a favorite arriving via WebDAV
/// had no cover row on the receiving device and rendered the text placeholder
/// until the user happened to open the thread. Syncing the rows themselves
/// fixes that and also carries the user-intent bits (manual cover, forced
/// text cover, dynamic toggle) across devices.
///
/// Whole rows merge by `updatedAt` — the store bumps one `updatedAt` per row
/// on every write, so the row is the store's own conflict granularity. There
/// are no tombstones: no user flow deletes a single row (`clearAll` is a
/// storage-cleanup action, and covers regrowing from the remote afterwards
/// matches how cleared offline caches re-download too).
struct ContentCoverWebDAVParticipant: WebDAVSyncParticipant {
    let datasetID = "contentCovers"
    let remoteFileName = "yamibox-content-covers-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let store: ContentCoverStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: ContentCoverStore) {
        self.store = store
    }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try decoder.decode(ContentCoverWebDAVPayload.self, from: data)
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, revision: payload.syncRevision)
    }

    func mergeAndExport(remoteData: Data?, updatedAt: Date, accountUID _: String) async throws -> Data {
        let local = ContentCoverWebDAVPayload(
            updatedAt: updatedAt,
            covers: try await store.allCovers()
        )
        let remote = try remoteData.map { try decoder.decode(ContentCoverWebDAVPayload.self, from: $0) }
        let merged = ContentCoverWebDAVMerger().merge(local: local, remote: remote, updatedAt: updatedAt)
        try await store.replaceAll(merged.covers)
        return try encoder.encode(merged)
    }

    func applyRemote(_ data: Data) async throws {
        let payload = try decoder.decode(ContentCoverWebDAVPayload.self, from: data)
        try await store.replaceAll(payload.covers)
    }

    // Hashed rather than base64-of-full-JSON (unlike AppSettingsWebDAVParticipant):
    // this dataset holds one row per ever-covered thread, and the fingerprint is
    // persisted inside the (already UserDefaults-backed) WebDAVSyncSettings blob.
    // `allCovers()` returns rows in a stable order, so equal data hashes equal.
    func localFingerprint() async -> String? {
        let covers: [ContentCover]
        do {
            covers = try await store.allCovers()
        } catch {
            YamiboLog.sync.warning("Failed to load content covers for WebDAV fingerprint: \(error)")
            return nil
        }
        let fingerprintEncoder = JSONEncoder()
        fingerprintEncoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try fingerprintEncoder.encode(covers)
        } catch {
            YamiboLog.sync.warning("Failed to encode content cover fingerprint for WebDAV sync: \(error)")
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ContentCoverWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var updatedAt: Date
    /// Monotonic per-dataset sync revision, stamped into the envelope by the
    /// sync service after export; nil for payloads written before revisions
    /// existed (decode falls back to `updatedAt` comparisons then).
    var syncRevision: UInt64?
    var covers: [ContentCover]

    init(version: Int = Self.currentVersion, updatedAt: Date, syncRevision: UInt64? = nil, covers: [ContentCover]) {
        self.version = version
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
        self.covers = covers
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case syncRevision
        case covers
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
        self.covers = try container.decode([ContentCover].self, forKey: .covers)
    }
}

struct ContentCoverWebDAVMerger: Sendable {
    init() {}

    func merge(
        local: ContentCoverWebDAVPayload,
        remote: ContentCoverWebDAVPayload?,
        updatedAt: Date
    ) -> ContentCoverWebDAVPayload {
        guard let remote else {
            return ContentCoverWebDAVPayload(updatedAt: updatedAt, covers: local.covers)
        }
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: Codable
        // decoding bypasses the store's write paths, so a hand-edited or
        // buggy-peer payload can carry duplicate keys — that must degrade to
        // keep-newest, not crash every future sync round (same tolerance as
        // `FavoriteLibraryWebDAVMerger`).
        var byKey = Dictionary(local.covers.map { ($0.key, $0) }, uniquingKeysWith: Self.newerCover)
        for cover in remote.covers {
            if let existing = byKey[cover.key], existing.updatedAt >= cover.updatedAt {
                continue
            }
            byKey[cover.key] = cover
        }
        return ContentCoverWebDAVPayload(
            updatedAt: updatedAt,
            covers: byKey.values.sorted {
                if $0.key.targetType != $1.key.targetType { return $0.key.targetType.rawValue < $1.key.targetType.rawValue }
                return $0.key.targetID < $1.key.targetID
            }
        )
    }

    private static func newerCover(_ lhs: ContentCover, _ rhs: ContentCover) -> ContentCover {
        lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }
}

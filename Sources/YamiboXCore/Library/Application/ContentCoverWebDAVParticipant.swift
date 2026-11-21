import CryptoKit
import Foundation

struct ContentCoverWebDAVParticipant: MangaIdentitySyncParticipant {
    var mangaIdentityStrategy: MangaIdentityPayloadStrategy? {
        MangaIdentityPayloadStrategy(
            legacyRecordCollection: "covers",
            legacyRecordDeletion: { record in
                let key = record["key"] as? [String: Any]
                let keys = (key?["targetType"] as? String).flatMap { type in
                    (key?["targetID"] as? String).map { [type + ":" + $0] }
                } ?? []
                return MangaIdentityLegacyDeletion(keys: keys, date: record["updatedAt"] as? Double)
            },
            normalizePayload: ContentCoverWebDAVPayload.normalizingMangaIdentities
        )
    }

    let datasetID = "contentCovers"
    let remoteFileName = "yamibox-content-covers-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let store: ContentCoverStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: ContentCoverStore) {
        self.store = store
    }

    func readLocalDeletionState() async throws -> SyncDeletionState? { try await store.syncSnapshot().deletions }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try decoder.decode(ContentCoverWebDAVPayload.self, from: data)
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, revision: payload.syncRevision)
    }

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID _: String) async throws -> WebDAVExportSnapshot {
        let remote = try remoteData.map { try decoder.decode(ContentCoverWebDAVPayload.self, from: $0) }
        let merged = try await merge(remote: remote, at: updatedAt)
        return WebDAVExportSnapshot(data: try encoder.encode(merged), fingerprint: try merged.contentFingerprint())
    }

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot {
        let payload = try decoder.decode(ContentCoverWebDAVPayload.self, from: data)
        let merged = try await merge(remote: payload, at: payload.updatedAt)
        let fingerprint = try merged.contentFingerprint()
        return WebDAVApplySnapshot(fingerprint: fingerprint, requiresUpload: fingerprint != (try payload.contentFingerprint()))
    }

    private func merge(remote: ContentCoverWebDAVPayload?, at date: Date) async throws -> ContentCoverWebDAVPayload {
        let remoteSnapshot = remote.map { SyncRecordSnapshot(records: $0.covers, deletions: $0.deletions) }
        return try await store.updateSyncSnapshot(merging: remoteSnapshot) { snapshot, remoteSnapshot in
            let local = ContentCoverWebDAVPayload(updatedAt: date, covers: snapshot.records, deletions: snapshot.deletions)
            let remote = remoteSnapshot.map {
                ContentCoverWebDAVPayload(updatedAt: date, covers: $0.records, deletions: $0.deletions)
            }
            let merged = ContentCoverWebDAVMerger().merge(local: local, remote: remote, updatedAt: date)
            snapshot = SyncRecordSnapshot(records: merged.covers, deletions: merged.deletions)
            return merged
        }
    }

    func readLocalFingerprint() async throws -> String? {
        let snapshot = try await store.syncSnapshot()
        return try ContentCoverWebDAVPayload(updatedAt: .distantPast, covers: snapshot.records,
            deletions: snapshot.deletions).contentFingerprint()
    }
}

struct ContentCoverWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var updatedAt: Date
    var syncRevision: UInt64?
    var covers: [ContentCover]
    var deletions: SyncDeletionState

    init(version: Int = Self.currentVersion, updatedAt: Date, syncRevision: UInt64? = nil, covers: [ContentCover], deletions: SyncDeletionState = .init()) {
        self.version = version
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
        self.covers = covers
        self.deletions = deletions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case syncRevision
        case covers
        case deletions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(Int.self, forKey: .version) else {
            throw WebDAVSyncError.unsupportedPayloadVersion(0)
        }
        guard version == 1 || version == Self.currentVersion else {
            throw WebDAVSyncError.unsupportedPayloadVersion(version)
        }
        self.version = version
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.syncRevision = try container.decodeIfPresent(UInt64.self, forKey: .syncRevision)
        self.covers = try container.decode([ContentCover].self, forKey: .covers)
        self.deletions = version == 1 ? .init() : try container.decode(SyncDeletionState.self, forKey: .deletions)
    }

    func contentFingerprint() throws -> String {
        try WebDAVSyncFingerprint.make(SyncRecordSnapshot(
            records: covers.sorted { $0.key.syncID < $1.key.syncID }, deletions: deletions))
    }
}

struct ContentCoverWebDAVMerger: Sendable {
    init() {}

    func merge(
        local: ContentCoverWebDAVPayload,
        remote: ContentCoverWebDAVPayload?,
        updatedAt: Date
    ) -> ContentCoverWebDAVPayload {
        let deletions = local.deletions.merging(remote?.deletions ?? .init())
        var byKey = Dictionary(local.covers.map { ($0.key, $0) }, uniquingKeysWith: Self.newerCover)
        for cover in remote?.covers ?? [] {
            byKey[cover.key] = byKey[cover.key].map { Self.newerCover($0, cover) } ?? cover
        }
        return ContentCoverWebDAVPayload(
            updatedAt: updatedAt,
            covers: byKey.values.filter { !deletions.containsDeletion(of: $0.key.syncID, updatedAt: $0.updatedAt) }.sorted {
                if $0.key.targetType != $1.key.targetType { return $0.key.targetType.rawValue < $1.key.targetType.rawValue }
                return $0.key.targetID < $1.key.targetID
            },
            deletions: deletions
        )
    }

    private static func newerCover(_ lhs: ContentCover, _ rhs: ContentCover) -> ContentCover {
        lhs.updatedAt >= rhs.updatedAt
            ? lhs.retainingKnownSources(from: rhs)
            : rhs.retainingKnownSources(from: lhs)
    }
}

private extension ContentCoverWebDAVPayload {
    static func normalizingMangaIdentities(_ data: Data, _ identities: MangaDirectoryIdentitySnapshot, _: [Int: MangaIdentityLegacyTarget]) throws -> Data {
        var payload = try JSONDecoder().decode(Self.self, from: data)
        for index in payload.covers.indices where payload.covers[index].key.targetType == .smartManga {
            payload.covers[index].key.targetID = identities.resolve(payload.covers[index].key.targetID, legacy: false)
        }
        payload.deletions = MangaIdentityDeletionRemapping.normalize(payload.deletions, identities: identities)
        return try JSONEncoder().encode(payload)
    }
}

import Foundation

struct BrowsingHistoryWebDAVPayload: Codable, Equatable, Sendable {
    var version = 1
    var updatedAt: Date
    var syncRevision: UInt64?
    var accountUID: String?
    var records: [BrowsingHistorySyncRecord]
    var deletions = SyncDeletionState()

    static func decode(_ data: Data) throws -> Self {
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard payload.version == 1 else { throw WebDAVSyncError.unsupportedPayloadVersion(payload.version) }
        guard payload.records.allSatisfy({ record in
            let source = record.threadID
            let name = record.target.mangaCleanBookName
            let mangaID = record.target.mangaID
            return source?.trimmingCharacters(in: .whitespacesAndNewlines) != ""
                && source == source?.trimmingCharacters(in: .whitespacesAndNewlines)
                && name?.trimmingCharacters(in: .whitespacesAndNewlines) != ""
                && mangaID?.trimmingCharacters(in: .whitespacesAndNewlines) != ""
        }) else {
            throw YamiboPersistenceError(context: "Invalid synchronized browsing history")
        }
        return payload
    }

    func contentFingerprint() throws -> String {
        try WebDAVSyncFingerprint.make(SyncRecordSnapshot(records: records.sorted { $0.id < $1.id }, deletions: deletions))
    }

    func merging(_ remote: Self?) throws -> Self {
        let snapshot = try BrowsingHistorySyncMergeV1.merge(
            SyncRecordSnapshot(records: records, deletions: deletions),
            remote.map { SyncRecordSnapshot(records: $0.records, deletions: $0.deletions) }
        )
        var result = self
        result.records = snapshot.records
        result.deletions = snapshot.deletions
        return result
    }
}

struct BrowsingHistoryWebDAVParticipant: MangaIdentitySyncParticipant {
    var mangaIdentityStrategy: MangaIdentityPayloadStrategy? {
        MangaIdentityPayloadStrategy(
            legacyTargetField: "target",
            legacyRecordDeletion: { record in
                let target = (record["contentTarget"] ?? record["target"]) as? [String: Any]
                guard target?["kind"] as? String == "mangaTitle" else { return nil }
                return MangaIdentityLegacyDeletion(
                    keys: ((target?["mangaID"] ?? target?["cleanBookName"]) as? String).map { ["manga-title:" + $0] } ?? [],
                    date: (record["updatedAt"] ?? record["lastVisitTime"]) as? Double
                )
            },
            contentFingerprint: { try BrowsingHistoryWebDAVPayload.decode($0).contentFingerprint() },
            currentTargetReferences: BrowsingHistoryWebDAVPayload.mangaTargetReferences,
            normalizePayload: BrowsingHistoryWebDAVPayload.normalizingMangaIdentities
        )
    }

    let datasetID = WebDAVSyncContent.browsingHistory.rawValue
    let remoteFileName = "yamibox-browsing-history-v1.json"
    let uploadsOnlyWhenMarkedDirty = true
    let uploadsUntrackedContentAutomatically = true
    let store: BrowsingHistoryStore

    func readLocalDeletionState() async throws -> SyncDeletionState? { try await store.syncSnapshot().deletions }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try BrowsingHistoryWebDAVPayload.decode(data)
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, accountUID: payload.accountUID, revision: payload.syncRevision)
    }

    func readLocalFingerprint() async throws -> String? {
        let snapshot = try await store.syncSnapshot()
        return try BrowsingHistoryWebDAVPayload(updatedAt: .distantPast, records: snapshot.records, deletions: snapshot.deletions).contentFingerprint()
    }

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> WebDAVExportSnapshot {
        var merged = try await merge(remoteData: remoteData, at: updatedAt)
        merged.accountUID = accountUID
        return try WebDAVExportSnapshot(data: JSONEncoder().encode(merged), fingerprint: merged.contentFingerprint())
    }

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot {
        let remote = try BrowsingHistoryWebDAVPayload.decode(data)
        let merged = try await merge(remoteData: data, at: remote.updatedAt)
        let fingerprint = try merged.contentFingerprint()
        return try WebDAVApplySnapshot(fingerprint: fingerprint, requiresUpload: fingerprint != remote.contentFingerprint())
    }

    private func merge(remoteData: Data?, at date: Date) async throws -> BrowsingHistoryWebDAVPayload {
        let remote = try remoteData.map(BrowsingHistoryWebDAVPayload.decode)
        let remoteSnapshot = remote.map { SyncRecordSnapshot(records: $0.records, deletions: $0.deletions) }
        return try await store.updateSyncSnapshot(merging: remoteSnapshot) { snapshot, remoteSnapshot in
            let remote = remoteSnapshot.map {
                BrowsingHistoryWebDAVPayload(updatedAt: date, records: $0.records, deletions: $0.deletions)
            }
            let merged = try BrowsingHistoryWebDAVPayload(updatedAt: date, records: snapshot.records, deletions: snapshot.deletions).merging(remote)
            snapshot = SyncRecordSnapshot(records: merged.records, deletions: merged.deletions)
            return merged
        }
    }
}

private extension BrowsingHistoryWebDAVPayload {
    static func mangaTargetReferences(_ data: Data) throws -> [MangaIdentityTargetReference] {
        try decode(data).records.enumerated().compactMap { index, record in
            guard case let .mangaTitle(id, name) = record.target else { return nil }
            return MangaIdentityTargetReference(index: index, name: name, identity: id, chapterTID: record.threadID)
        }
    }

    static func normalizingMangaIdentities(_ data: Data, _ identities: MangaDirectoryIdentitySnapshot, _ resolvedTargets: [Int: MangaIdentityLegacyTarget]) throws -> Data {
        var payload = try decode(data)
        for index in payload.records.indices {
            if let target = resolvedTargets[index] {
                payload.records[index].target = .mangaTitle(mangaID: identities.canonicalID(target.id), cleanBookName: target.name)
                continue
            }
            payload.records[index].target = FavoriteContentIdentityRemapping.normalize(
                payload.records[index].target, identities: identities, legacy: false)
        }
        payload.deletions = MangaIdentityDeletionRemapping.normalize(payload.deletions, identities: identities)
        return try JSONEncoder().encode(payload)
    }
}

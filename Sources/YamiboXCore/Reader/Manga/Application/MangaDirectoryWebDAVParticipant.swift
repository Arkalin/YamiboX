import Foundation

struct MangaDirectorySyncRecord: Codable, Equatable, Sendable {
    var directory: MangaDirectory
    var modifiedAt: Date
    var id: String { directory.cleanBookName }
}

struct MangaDirectoryWebDAVPayload: Codable, Equatable, Sendable {
    var version = 1
    var updatedAt: Date
    var syncRevision: UInt64?
    var accountUID: String?
    var records: [MangaDirectorySyncRecord]
    var deletions = SyncDeletionState()

    static func decode(_ data: Data) throws -> Self {
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard payload.version == 1 else { throw WebDAVSyncError.unsupportedPayloadVersion(payload.version) }
        for record in payload.records {
            guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.id == record.id.trimmingCharacters(in: .whitespacesAndNewlines),
                  record.directory.chapters.allSatisfy({ !$0.tid.isEmpty && $0.tid == $0.tid.trimmingCharacters(in: .whitespacesAndNewlines) }),
                  Set(record.directory.chapters.map(\.tid)).count == record.directory.chapters.count else {
                throw YamiboPersistenceError(context: "Invalid synchronized manga directory")
            }
        }
        return payload
    }

    func contentFingerprint() throws -> String {
        try WebDAVSyncFingerprint.make(SyncRecordSnapshot(records: records.sorted { $0.id < $1.id }, deletions: deletions))
    }

    func merging(_ remote: Self?) throws -> Self {
        var result = self
        result.deletions = deletions.merging(remote?.deletions ?? .init())
        var byID: [String: MangaDirectorySyncRecord] = [:]
        for record in records + (remote?.records ?? []) {
            if let existing = byID[record.id] {
                if existing.modifiedAt > record.modifiedAt { continue }
                if existing.modifiedAt == record.modifiedAt,
                   try WebDAVSyncFingerprint.make(existing) >= WebDAVSyncFingerprint.make(record) { continue }
            }
            byID[record.id] = record
        }
        result.records = byID.values.filter {
            !result.deletions.containsDeletion(of: $0.id, updatedAt: $0.modifiedAt)
        }.sorted { $0.id < $1.id }
        return result
    }
}

struct MangaDirectoryWebDAVParticipant: WebDAVSyncParticipant {
    let datasetID = WebDAVSyncContent.mangaDirectories.rawValue
    let remoteFileName = "yamibox-manga-directories-v1.json"
    let uploadsOnlyWhenMarkedDirty = true
    let uploadsUntrackedContentAutomatically = true
    let store: MangaDirectoryStore

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try MangaDirectoryWebDAVPayload.decode(data)
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, accountUID: payload.accountUID, revision: payload.syncRevision)
    }

    func readLocalFingerprint() async throws -> String? {
        let snapshot = try await store.syncSnapshot()
        return try MangaDirectoryWebDAVPayload(updatedAt: .distantPast, records: snapshot.records, deletions: snapshot.deletions).contentFingerprint()
    }

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> WebDAVExportSnapshot {
        var merged = try await merge(remoteData: remoteData, at: updatedAt)
        merged.accountUID = accountUID
        return try WebDAVExportSnapshot(data: JSONEncoder().encode(merged), fingerprint: merged.contentFingerprint())
    }

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot {
        let remote = try MangaDirectoryWebDAVPayload.decode(data)
        let merged = try await merge(remoteData: data, at: remote.updatedAt)
        let fingerprint = try merged.contentFingerprint()
        return try WebDAVApplySnapshot(fingerprint: fingerprint, requiresUpload: fingerprint != remote.contentFingerprint())
    }

    private func merge(remoteData: Data?, at date: Date) async throws -> MangaDirectoryWebDAVPayload {
        let remote = try remoteData.map(MangaDirectoryWebDAVPayload.decode)
        return try await store.updateSyncSnapshot { snapshot in
            let merged = try MangaDirectoryWebDAVPayload(updatedAt: date, records: snapshot.records, deletions: snapshot.deletions).merging(remote)
            snapshot = SyncRecordSnapshot(records: merged.records, deletions: merged.deletions)
            return merged
        }
    }
}

import Foundation

struct MangaDirectorySyncRecord: Codable, Equatable, Sendable {
    var directory: MangaDirectory
    var modifiedAt: Date
    /// Content lineage, independent of identity redirects imported by other datasets.
    var contentIdentityIDs: Set<String>
    var id: String { directory.id.rawValue }

    init(directory: MangaDirectory, modifiedAt: Date, contentIdentityIDs: Set<String>? = nil) {
        self.directory = directory
        self.modifiedAt = modifiedAt
        self.contentIdentityIDs = contentIdentityIDs ?? [directory.id.rawValue]
    }

    private enum CodingKeys: CodingKey { case directory, modifiedAt, contentIdentityIDs }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let directory = try values.decode(MangaDirectory.self, forKey: .directory)
        self.init(directory: directory, modifiedAt: try values.decode(Date.self, forKey: .modifiedAt),
            contentIdentityIDs: try values.decodeIfPresent(Set<String>.self, forKey: .contentIdentityIDs))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(directory, forKey: .directory)
        try values.encode(modifiedAt, forKey: .modifiedAt)
        try values.encode(contentIdentityIDs.sorted(), forKey: .contentIdentityIDs)
    }
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
                  !record.directory.cleanBookName.isEmpty,
                  record.directory.cleanBookName == record.directory.cleanBookName.trimmingCharacters(in: .whitespacesAndNewlines),
                  record.directory.chapters.allSatisfy({ !$0.tid.isEmpty && $0.tid == $0.tid.trimmingCharacters(in: .whitespacesAndNewlines) }),
                  !record.contentIdentityIDs.isEmpty,
                  record.contentIdentityIDs.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
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
            // A content union must not advance a deleted snapshot past its tombstone.
            guard !result.deletions.containsDeletion(of: record.id, updatedAt: record.modifiedAt) else { continue }
            if let existing = byID[record.id] {
                let prefersExisting: Bool
                if existing.modifiedAt == record.modifiedAt {
                    prefersExisting = try WebDAVSyncFingerprint.make(existing) >= WebDAVSyncFingerprint.make(record)
                } else {
                    prefersExisting = existing.modifiedAt > record.modifiedAt
                }
                var winner = prefersExisting ? existing : record
                let other = prefersExisting ? record : existing
                if !winner.contentIdentityIDs.isSuperset(of: other.contentIdentityIDs) {
                    winner.directory.chapters = MangaDirectoryMerge.mergeAndSort(other.directory.chapters, winner.directory.chapters)
                    winner.contentIdentityIDs.formUnion(other.contentIdentityIDs)
                    winner.modifiedAt = max(existing.modifiedAt, record.modifiedAt).addingTimeInterval(0.001)
                }
                // Once the winning content includes both origins, normal LWW
                // refreshes (including deliberate chapter removals) remain intact.
                byID[record.id] = winner
                continue
            }
            byID[record.id] = record
        }
        result.records = byID.values.filter {
            !result.deletions.containsDeletion(of: $0.id, updatedAt: $0.modifiedAt)
        }.sorted { $0.id < $1.id }
        return result
    }
}

struct MangaDirectoryWebDAVParticipant: MangaIdentitySyncParticipant {
    var mangaIdentityStrategy: MangaIdentityPayloadStrategy? {
        MangaIdentityPayloadStrategy(
            legacyRecordDeletion: { record in
                MangaIdentityLegacyDeletion(
                    keys: ((record["directory"] as? [String: Any])?["cleanBookName"] as? String).map { [$0] } ?? [],
                    date: record["modifiedAt"] as? Double
                )
            },
            prepareForNormalization: { data in
                // Capture old content lineage before rewriting directory IDs.
                try JSONEncoder().encode(MangaDirectoryWebDAVPayload.decode(data))
            },
            contentFingerprint: { try MangaDirectoryWebDAVPayload.decode($0).contentFingerprint() },
            normalizePayload: MangaDirectoryWebDAVPayload.normalizingMangaIdentities
        )
    }

    let datasetID = WebDAVSyncContent.mangaDirectories.rawValue
    let remoteFileName = "yamibox-manga-directories-v1.json"
    let uploadsOnlyWhenMarkedDirty = true
    let uploadsUntrackedContentAutomatically = true
    let store: MangaDirectoryStore

    func readLocalDeletionState() async throws -> SyncDeletionState? { try await store.syncSnapshot().deletions }

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
        let remoteSnapshot = remote.map { SyncRecordSnapshot(records: $0.records, deletions: $0.deletions) }
        return try await store.updateSyncSnapshot(merging: remoteSnapshot) { snapshot, remoteSnapshot in
            let remote = remoteSnapshot.map {
                MangaDirectoryWebDAVPayload(updatedAt: date, records: $0.records, deletions: $0.deletions)
            }
            let merged = try MangaDirectoryWebDAVPayload(updatedAt: date, records: snapshot.records, deletions: snapshot.deletions).merging(remote)
            snapshot = SyncRecordSnapshot(records: merged.records, deletions: merged.deletions)
            return merged
        }
    }
}

private extension MangaDirectoryWebDAVPayload {
    static func normalizingMangaIdentities(_ data: Data, _ identities: MangaDirectoryIdentitySnapshot, _: [Int: MangaIdentityLegacyTarget]) throws -> Data {
        var payload = try decode(data)
        for index in payload.records.indices {
            let directory = payload.records[index].directory
            let id = identities.resolve(directory.id.rawValue, name: directory.cleanBookName, legacy: false)
            payload.records[index].directory = directory.reidentified(as: MangaDirectoryID(rawValue: id))
            if let title = identities.titles[id], title != id {
                payload.records[index].directory.cleanBookName = title
            }
        }
        payload.deletions = MangaIdentityDeletionRemapping.normalize(payload.deletions,
            identities: identities, directoryKeys: true)
        return try JSONEncoder().encode(payload)
    }
}

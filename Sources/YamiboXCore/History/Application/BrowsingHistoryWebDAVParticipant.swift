import Foundation
@preconcurrency import GRDB

/// Stable visit data, independent of the device's reader mode and progress projection.
struct BrowsingHistorySyncRecord: Codable, Equatable, Sendable {
    var target: FavoriteContentTarget
    var threadID: String?
    var title: String
    var forumID: String?
    var authorID: String?
    var lastVisitTime: Date
    var id: String { threadID.map { "source:\($0)" } ?? target.id }

    init(_ entry: BrowsingHistoryEntry) {
        target = entry.target
        threadID = entry.lastVisitedThreadID ?? entry.target.threadID
        title = entry.lastVisitedThreadTitle ?? entry.title
        forumID = entry.forumID
        authorID = entry.authorID
        lastVisitTime = entry.lastVisitTime
    }

    var entry: BrowsingHistoryEntry {
        BrowsingHistoryEntry(target: target, title: target.mangaCleanBookName ?? title,
            forumID: forumID, authorID: authorID, chapterThreadID: target.kind == .mangaTitle ? threadID : nil,
            lastVisitTime: lastVisitTime, lastVisitedThreadID: threadID, lastVisitedThreadTitle: title)
    }

    static func load(in db: Database) throws -> [Self] {
        try Data.fetchAll(db, sql: "SELECT record FROM browsing_history_sync_records ORDER BY id").map {
            try JSONDecoder().decode(Self.self, from: $0)
        }
    }

    static func save(_ records: [Self], in db: Database) throws {
        try db.execute(sql: "DELETE FROM browsing_history_sync_records")
        for record in records {
            try record.save(in: db)
        }
    }

    func save(in db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO browsing_history_sync_records (id, record, last_visit_time) VALUES (?, ?, ?)",
            arguments: [id, try JSONEncoder().encode(self), lastVisitTime.timeIntervalSince1970])
    }
}

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
        var result = self
        result.deletions = deletions.merging(remote?.deletions ?? .init())
        var byID: [String: BrowsingHistorySyncRecord] = [:]
        for record in records + (remote?.records ?? []) {
            if let existing = byID[record.id] {
                if existing.lastVisitTime > record.lastVisitTime { continue }
                if existing.lastVisitTime == record.lastVisitTime,
                   try WebDAVSyncFingerprint.make(existing) >= WebDAVSyncFingerprint.make(record) { continue }
            }
            byID[record.id] = record
        }
        result.records = Array(byID.values.filter {
            !result.deletions.containsDeletion(of: $0.id, updatedAt: $0.lastVisitTime)
                && !result.deletions.containsDeletion(of: $0.target.id, updatedAt: $0.lastVisitTime)
        }.sorted {
            $0.lastVisitTime == $1.lastVisitTime ? $0.id < $1.id : $0.lastVisitTime > $1.lastVisitTime
        }.prefix(BrowsingHistoryStore.maxEntryCount))
        return result
    }
}

struct BrowsingHistoryWebDAVParticipant: WebDAVSyncParticipant {
    let datasetID = WebDAVSyncContent.browsingHistory.rawValue
    let remoteFileName = "yamibox-browsing-history-v1.json"
    let uploadsOnlyWhenMarkedDirty = true
    let uploadsUntrackedContentAutomatically = true
    let store: BrowsingHistoryStore

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
        return try await store.updateSyncSnapshot { snapshot in
            let merged = try BrowsingHistoryWebDAVPayload(updatedAt: date, records: snapshot.records, deletions: snapshot.deletions).merging(remote)
            snapshot = SyncRecordSnapshot(records: merged.records, deletions: merged.deletions)
            return merged
        }
    }
}

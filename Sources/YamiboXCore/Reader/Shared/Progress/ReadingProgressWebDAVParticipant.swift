import CryptoKit
import Foundation

/// WebDAV sync participant for reading progress. Owns the payload format and
/// newest-record-wins merge semantics for progress records.
struct ReadingProgressWebDAVParticipant: WebDAVSyncParticipant {
    let datasetID = "readingProgress"
    let remoteFileName = "yamibox-reading-progress-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let store: ReadingProgressStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: ReadingProgressStore) {
        self.store = store
    }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try decoder.decode(ReadingProgressWebDAVPayload.self, from: data)
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt, revision: payload.syncRevision)
    }

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID _: String) async throws -> WebDAVExportSnapshot {
        let remote = try remoteData.map { try decoder.decode(ReadingProgressWebDAVPayload.self, from: $0) }
        let merged = try await merge(remote: remote, at: updatedAt)
        return WebDAVExportSnapshot(data: try encoder.encode(merged), fingerprint: try merged.contentFingerprint())
    }

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot {
        let payload = try decoder.decode(ReadingProgressWebDAVPayload.self, from: data)
        let merged = try await merge(remote: payload, at: payload.updatedAt)
        let fingerprint = try merged.contentFingerprint()
        return WebDAVApplySnapshot(fingerprint: fingerprint, requiresUpload: fingerprint != (try payload.contentFingerprint()))
    }

    private func merge(remote: ReadingProgressWebDAVPayload?, at date: Date) async throws -> ReadingProgressWebDAVPayload {
        try await store.updateSyncSnapshot { snapshot in
            let local = ReadingProgressWebDAVPayload(updatedAt: date, records: snapshot.records, deletions: snapshot.deletions)
            let merged = ReadingProgressWebDAVMerger().merge(local: local, remote: remote, updatedAt: date)
            snapshot = SyncRecordSnapshot(records: merged.records, deletions: merged.deletions)
            return merged
        }
    }

    func readLocalFingerprint() async throws -> String? {
        let snapshot = try await store.syncSnapshot()
        return try ReadingProgressWebDAVPayload(updatedAt: .distantPast, records: snapshot.records,
            deletions: snapshot.deletions).contentFingerprint()
    }
}

struct ReadingProgressWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 3

    var version: Int
    var updatedAt: Date
    /// Monotonic per-dataset sync revision, stamped into the envelope by the
    /// sync service after export; nil for payloads written before revisions
    /// existed (decode falls back to `updatedAt` comparisons then).
    var syncRevision: UInt64?
    var records: [ReadingProgressRecord]
    var deletions: SyncDeletionState

    init(version: Int = Self.currentVersion, updatedAt: Date, syncRevision: UInt64? = nil, records: [ReadingProgressRecord], deletions: SyncDeletionState = .init()) {
        self.version = version
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
        self.records = records
        self.deletions = deletions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case syncRevision
        case records
        case deletions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(Int.self, forKey: .version) else {
            throw WebDAVSyncError.unsupportedPayloadVersion(0)
        }
        guard version == 2 || version == Self.currentVersion else {
            throw WebDAVSyncError.unsupportedPayloadVersion(version)
        }
        self.version = version
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.syncRevision = try container.decodeIfPresent(UInt64.self, forKey: .syncRevision)
        self.records = try container.decode([ReadingProgressWebDAVRecord].self, forKey: .records)
            .map { try $0.record() }
        self.deletions = version == 2 ? .init() : try container.decode(SyncDeletionState.self, forKey: .deletions)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(syncRevision, forKey: .syncRevision)
        try container.encode(try records.map { try ReadingProgressWebDAVRecord(record: $0) }, forKey: .records)
        try container.encode(deletions, forKey: .deletions)
    }

    func contentFingerprint() throws -> String {
        try WebDAVSyncFingerprint.make(SyncRecordSnapshot(
            records: records.sorted { $0.id < $1.id }.map { try ReadingProgressWebDAVRecord(record: $0) },
            deletions: deletions))
    }
}

struct ReadingProgressWebDAVMerger: Sendable {
    init() {}

    func merge(
        local: ReadingProgressWebDAVPayload,
        remote: ReadingProgressWebDAVPayload?,
        updatedAt: Date
    ) -> ReadingProgressWebDAVPayload {
        let deletions = local.deletions.merging(remote?.deletions ?? .init())
        var byID = Dictionary(local.records.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        for record in remote?.records ?? [] {
            if let existing = byID[record.id], existing.updatedAt >= record.updatedAt {
                continue
            }
            byID[record.id] = record
        }
        return ReadingProgressWebDAVPayload(
            version: ReadingProgressWebDAVPayload.currentVersion,
            updatedAt: updatedAt,
            records: byID.values.filter { !deletions.containsDeletion(of: $0.id, updatedAt: $0.updatedAt) }.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            },
            deletions: deletions
        )
    }
}

private struct ReadingProgressWebDAVRecord: Codable, Equatable, Sendable {
    var contentTarget: FavoriteContentTarget
    var kind: ReadingProgressKind
    var updatedAt: Date
    var lastReadAt: Date?
    var threadID: String?
    var novel: NovelReadingProgressRecord?
    var manga: MangaReadingProgressWebDAVRecord?
    var thread: ThreadReadingProgressRecord?

    init(record: ReadingProgressRecord) throws {
        guard let contentTarget = record.contentTarget else {
            throw EncodingError.invalidValue(
                record,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Reading progress WebDAV records require an explicit contentTarget."
                )
            )
        }
        self.contentTarget = contentTarget
        self.kind = record.kind
        self.updatedAt = record.updatedAt
        self.lastReadAt = record.lastReadAt
        self.threadID = record.threadID
        self.novel = record.novel
        if let manga = record.manga {
            self.manga = MangaReadingProgressWebDAVRecord(
                chapterThreadID: manga.chapterThreadID,
                chapterView: manga.chapterView,
                lastChapter: manga.lastChapter,
                mangaPageIndex: manga.mangaPageIndex,
                mangaPageCount: manga.mangaPageCount
            )
        } else {
            self.manga = nil
        }
        self.thread = record.thread
    }

    func record() throws -> ReadingProgressRecord {
        let resolvedThreadID = contentTarget.threadID ?? threadID ?? manga?.chapterThreadID
        let mangaRecord: MangaReadingProgressRecord?
        if let payload = manga {
            guard let chapterThreadID = payload.chapterThreadID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !chapterThreadID.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Manga reading progress WebDAV records require chapterThreadID."
                    )
                )
            }
            mangaRecord = MangaReadingProgressRecord(
                chapterThreadID: chapterThreadID,
                chapterView: payload.chapterView,
                lastChapter: payload.lastChapter,
                mangaPageIndex: payload.mangaPageIndex,
                mangaPageCount: payload.mangaPageCount
            )
        } else {
            mangaRecord = nil
        }
        return ReadingProgressRecord(
            contentTarget: contentTarget,
            threadID: resolvedThreadID,
            kind: kind,
            updatedAt: updatedAt,
            lastReadAt: lastReadAt,
            novel: novel,
            manga: mangaRecord,
            thread: thread
        )
    }
}

private struct MangaReadingProgressWebDAVRecord: Codable, Equatable, Sendable {
    var chapterThreadID: String?
    var chapterView: Int
    var lastChapter: String
    var mangaPageIndex: Int
    var mangaPageCount: Int?
}

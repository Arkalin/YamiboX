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
        return WebDAVRemotePayloadInfo(updatedAt: payload.updatedAt)
    }

    func mergeAndExport(remoteData: Data?, updatedAt: Date, accountUID _: String) async throws -> Data {
        let local = ReadingProgressWebDAVPayload(
            updatedAt: updatedAt,
            records: await store.loadAll()
        )
        let remote = try remoteData.map { try decoder.decode(ReadingProgressWebDAVPayload.self, from: $0) }
        let merged = ReadingProgressWebDAVMerger().merge(local: local, remote: remote, updatedAt: updatedAt)
        try await store.replaceAll(merged.records)
        return try encoder.encode(merged)
    }

    func applyRemote(_ data: Data) async throws {
        let payload = try decoder.decode(ReadingProgressWebDAVPayload.self, from: data)
        try await store.replaceAll(payload.records)
    }

    // Hashed rather than base64-of-full-JSON (unlike AppSettingsWebDAVParticipant):
    // this dataset can hold thousands of records, and the fingerprint is persisted
    // inside the (already UserDefaults-backed) WebDAVSyncSettings blob.
    func localFingerprint() async -> String? {
        let records: [ReadingProgressWebDAVRecord]
        do {
            records = try await store.loadAll().map { try ReadingProgressWebDAVRecord(record: $0) }
        } catch {
            YamiboLog.sync.warning("Failed to build reading progress fingerprint for WebDAV sync: \(error)")
            return nil
        }
        let fingerprintEncoder = JSONEncoder()
        fingerprintEncoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try fingerprintEncoder.encode(records)
        } catch {
            YamiboLog.sync.warning("Failed to encode reading progress fingerprint for WebDAV sync: \(error)")
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReadingProgressWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var updatedAt: Date
    var records: [ReadingProgressRecord]

    init(version: Int = Self.currentVersion, updatedAt: Date, records: [ReadingProgressRecord]) {
        self.version = version
        self.updatedAt = updatedAt
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case records
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
        self.records = try container.decode([ReadingProgressWebDAVRecord].self, forKey: .records)
            .map { try $0.record() }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(try records.map { try ReadingProgressWebDAVRecord(record: $0) }, forKey: .records)
    }
}

struct ReadingProgressWebDAVMerger: Sendable {
    init() {}

    func merge(
        local: ReadingProgressWebDAVPayload,
        remote: ReadingProgressWebDAVPayload?,
        updatedAt: Date
    ) -> ReadingProgressWebDAVPayload {
        guard let remote else {
            return ReadingProgressWebDAVPayload(version: ReadingProgressWebDAVPayload.currentVersion, updatedAt: updatedAt, records: local.records)
        }
        var byID = Dictionary(uniqueKeysWithValues: local.records.map { ($0.id, $0) })
        for record in remote.records {
            if let existing = byID[record.id], existing.updatedAt >= record.updatedAt {
                continue
            }
            byID[record.id] = record
        }
        return ReadingProgressWebDAVPayload(
            version: ReadingProgressWebDAVPayload.currentVersion,
            updatedAt: updatedAt,
            records: byID.values.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
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

import CryptoKit
import Foundation
@preconcurrency import GRDB

// Frozen wire formats used by v1-v3, not application domain models.
extension MangaIdentityMigrationV1 {
    struct DirectoryID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        static func legacy(name: String) -> Self {
            let key = "yamibox/manga-directory/v1\u{0}" + name.trimmingCharacters(in: .whitespacesAndNewlines)
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return Self(rawValue: "manga-legacy:" + digest)
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid manga directory ID")
            }
            rawValue = value
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    enum ContentTargetKind: String, Codable, CaseIterable, Sendable {
        case normalThread
        case novelThread
        case mangaTitle
        case mangaThread
    }

    enum ContentTarget: Codable, Hashable, Identifiable, Sendable {
        case normalThread(threadID: String)
        case novelThread(threadID: String)
        case mangaTitle(mangaID: String, cleanBookName: String)
        case mangaThread(threadID: String)

        private enum CodingKeys: String, CodingKey {
            case kind
            case threadID
            case mangaID
            case cleanBookName
        }

        var id: String {
            switch self {
            case let .normalThread(threadID):
                "thread:normal:\(threadID)"
            case let .novelThread(threadID):
                "thread:novel:\(threadID)"
            case let .mangaTitle(mangaID, _):
                "manga-title:\(mangaID)"
            case let .mangaThread(threadID):
                "manga-thread:\(threadID)"
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        var kind: ContentTargetKind {
            switch self {
            case .normalThread:
                .normalThread
            case .novelThread:
                .novelThread
            case .mangaTitle:
                .mangaTitle
            case .mangaThread:
                .mangaThread
            }
        }

        var mangaID: String? {
            guard case let .mangaTitle(mangaID, _) = self else { return nil }
            return mangaID
        }

        var mangaCleanBookName: String? {
            guard case let .mangaTitle(_, cleanBookName) = self else { return nil }
            return cleanBookName
        }

        var threadID: String? {
            switch self {
            case let .normalThread(threadID), let .novelThread(threadID), let .mangaThread(threadID):
                threadID
            case .mangaTitle:
                nil
            }
        }

        init(kind: ContentTargetKind, threadID: String) {
            let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(!normalizedThreadID.isEmpty, "ContentTarget requires a Yamibo thread tid")
            switch kind {
            case .normalThread:
                self = .normalThread(threadID: normalizedThreadID)
            case .novelThread:
                self = .novelThread(threadID: normalizedThreadID)
            case .mangaTitle:
                self = .mangaTitle(mangaID: normalizedThreadID, cleanBookName: normalizedThreadID)
            case .mangaThread:
                self = .mangaThread(threadID: normalizedThreadID)
            }
        }

        init(mangaID: String, mangaCleanBookName: String) {
            let normalizedName = mangaCleanBookName.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedID = mangaID.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(!normalizedID.isEmpty, "A manga target requires a persisted directory ID")
            self = .mangaTitle(
                mangaID: normalizedID,
                cleanBookName: normalizedName
            )
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(ContentTargetKind.self, forKey: .kind)
            switch kind {
            case .normalThread:
                self = .normalThread(threadID: try Self.decodeThreadID(from: container))
            case .novelThread:
                self = .novelThread(threadID: try Self.decodeThreadID(from: container))
            case .mangaTitle:
                let cleanBookName = try container.decode(String.self, forKey: .cleanBookName)
                self = .mangaTitle(
                    mangaID: try container.decodeIfPresent(String.self, forKey: .mangaID) ?? cleanBookName,
                    cleanBookName: cleanBookName
                )
            case .mangaThread:
                self = .mangaThread(threadID: try Self.decodeThreadID(from: container))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            switch self {
            case let .normalThread(threadID), let .novelThread(threadID), let .mangaThread(threadID):
                try container.encode(threadID, forKey: .threadID)
            case let .mangaTitle(mangaID, cleanBookName):
                try container.encode(mangaID, forKey: .mangaID)
                try container.encode(cleanBookName, forKey: .cleanBookName)
            }
        }

        func renamedMangaTitle(to cleanBookName: String) -> ContentTarget {
            guard case let .mangaTitle(mangaID, _) = self else { return self }
            return ContentTarget(mangaID: mangaID, mangaCleanBookName: cleanBookName)
        }

        private static func decodeThreadID(
            from container: KeyedDecodingContainer<CodingKeys>
        ) throws -> String {
            if let threadID = try container.decodeIfPresent(String.self, forKey: .threadID)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !threadID.isEmpty {
                return threadID
            }
            throw DecodingError.keyNotFound(
                CodingKeys.threadID,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "ContentTarget requires threadID")
            )
        }
    }

    enum FavoriteTargetKind: String, Codable, CaseIterable, Sendable {
        case normalThread
        case novelThread
        case mangaThread
    }

    enum FavoriteTarget: Codable, Hashable, Identifiable, Sendable {
        case normalThread(threadID: String)
        case novelThread(threadID: String)
        case mangaThread(threadID: String)

        private enum CodingKeys: String, CodingKey {
            case kind
            case threadID
        }

        var id: String {
            switch self {
            case let .normalThread(threadID):
                "thread:normal:\(threadID)"
            case let .novelThread(threadID):
                "thread:novel:\(threadID)"
            case let .mangaThread(threadID):
                "manga-thread:\(threadID)"
            }
        }

        var kind: FavoriteTargetKind {
            switch self {
            case .normalThread:
                .normalThread
            case .novelThread:
                .novelThread
            case .mangaThread:
                .mangaThread
            }
        }

        var threadID: String? {
            switch self {
            case let .normalThread(threadID), let .novelThread(threadID), let .mangaThread(threadID):
                threadID
            }
        }

        init(kind: FavoriteTargetKind, threadID: String) {
            let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(!normalizedThreadID.isEmpty, "FavoriteTarget requires a Yamibo thread tid")
            switch kind {
            case .normalThread:
                self = .normalThread(threadID: normalizedThreadID)
            case .novelThread:
                self = .novelThread(threadID: normalizedThreadID)
            case .mangaThread:
                self = .mangaThread(threadID: normalizedThreadID)
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(FavoriteTargetKind.self, forKey: .kind)
            let threadID = try Self.decodeThreadID(from: container)
            switch kind {
            case .normalThread:
                self = .normalThread(threadID: threadID)
            case .novelThread:
                self = .novelThread(threadID: threadID)
            case .mangaThread:
                self = .mangaThread(threadID: threadID)
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            switch self {
            case let .normalThread(threadID), let .novelThread(threadID), let .mangaThread(threadID):
                try container.encode(threadID, forKey: .threadID)
            }
        }

        private static func decodeThreadID(
            from container: KeyedDecodingContainer<CodingKeys>
        ) throws -> String {
            if let threadID = try container.decodeIfPresent(String.self, forKey: .threadID)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !threadID.isEmpty {
                return threadID
            }
            throw DecodingError.keyNotFound(
                CodingKeys.threadID,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "FavoriteTarget requires threadID")
            )
        }
    }

    enum TargetMode: String, Codable, Hashable, Sendable {
        case normalThread
        case novelThread
        case mangaThread
        case mangaDirectory

        init(kind: FavoriteTargetKind) {
            switch kind {
            case .normalThread:
                self = .normalThread
            case .novelThread:
                self = .novelThread
            case .mangaThread:
                self = .mangaThread
            }
        }
    }

    enum TargetKey: Codable, Hashable, Sendable {
        case favorite(FavoriteTarget)
        case mangaDirectory(directoryID: DirectoryID)

        private static let mangaDirectoryIDPrefix = "manga-directory:"

        private enum CodingKeys: String, CodingKey { case favorite, mangaDirectory }
        private enum PayloadKeys: String, CodingKey { case _0, directoryID, cleanBookName }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.favorite) {
                let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .favorite)
                self = .favorite(try payload.decode(FavoriteTarget.self, forKey: ._0))
            } else {
                let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .mangaDirectory)
                if let id = try payload.decodeIfPresent(DirectoryID.self, forKey: .directoryID) {
                    self = .mangaDirectory(directoryID: id)
                } else {
                    self = .mangaDirectory(directoryID: .legacy(name: try payload.decode(String.self, forKey: .cleanBookName)))
                }
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .favorite(target):
                var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .favorite)
                try payload.encode(target, forKey: ._0)
            case let .mangaDirectory(id):
                var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .mangaDirectory)
                try payload.encode(id, forKey: .directoryID)
            }
        }

        var id: String {
            switch self {
            case let .favorite(target):
                target.id
            case let .mangaDirectory(directoryID):
                "\(Self.mangaDirectoryIDPrefix)\(directoryID.rawValue)"
            }
        }

        static func mangaDirectoryID(fromID id: String) -> DirectoryID? {
            guard id.hasPrefix(mangaDirectoryIDPrefix) else { return nil }
            return DirectoryID(rawValue: String(id.dropFirst(mangaDirectoryIDPrefix.count)))
        }
    }

    struct TrackedTarget: Codable, Hashable, Identifiable, Sendable {
        var target: TargetKey
        var title: String
        var mode: TargetMode
        var categoryIDs: Set<String>
        var fid: String?
        var forumName: String?
        var knownLatestPostID: String?
        var knownReplyCount: Int?
        var knownPageCount: Int?
        var knownChapterTIDs: Set<String>?
        var baselineReady: Bool
        var lastCheckedAt: Date?
        var lastUpdatedAt: Date?
        var lastError: String?
        var consecutiveFailures: Int

        var id: String { target.id }
    }

    struct UpdateEvent: Decodable {
        var id: String
        var target: TargetKey
        var title: String
        var mode: TargetMode
        var fid: String?
        var forumName: String?
        var summary: UpdateSummary
        var detailIDs: [String]
        var detectedAt: Date
        var readAt: Date?
        var dismissedAt: Date?
        var ambiguous: Bool
    }

    enum UpdateSummary: Decodable {
        case newReplies(count: Int)
        case newPages(count: Int)
        case newChapters(count: Int)
        case changed
    }

    struct HistoryRecord: Codable, Equatable, Sendable {
        var target: ContentTarget
        var threadID: String?
        var title: String
        var forumID: String?
        var authorID: String?
        var lastVisitTime: Date
        var id: String { threadID.map { "source:\($0)" } ?? target.id }

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
            var record = self
            record.target = try IdentityRegistry.canonicalTarget(target, in: db)
            try db.execute(sql: "INSERT OR REPLACE INTO browsing_history_sync_records (id, record, last_visit_time) VALUES (?, ?, ?)",
                arguments: [record.id, try JSONEncoder().encode(record), record.lastVisitTime.timeIntervalSince1970])
        }
    }

    struct DeletionState: Codable {
        var clearedAt: Date?
        var tombstones: [String: Date] = [:]

        static func load(from table: String, in db: Database) throws -> Self {
            guard let data = try Data.fetchOne(db, sql: "SELECT state FROM \(table) WHERE id = 1") else {
                return Self()
            }
            return try JSONDecoder().decode(Self.self, from: data)
        }

        func save(to table: String, in db: Database) throws {
            let data = try JSONEncoder().encode(self)
            try db.execute(sql: "INSERT OR REPLACE INTO \(table) (id, state) VALUES (1, ?)", arguments: [data])
        }
    }
}

import Foundation
@preconcurrency import GRDB

public enum ContentCoverTargetType: String, Codable, Hashable, Sendable, CaseIterable {
    /// Forum thread content, keyed by tid. Whether the thread reads as a novel
    /// or a normal thread is presentation, not content identity, so both share
    /// this type.
    case thread = "Thread"
    /// Manga directory content, keyed by the directory's `cleanBookName`.
    /// Renamed from `.mangaTitle`/`"MangaTitle"` (smart-comic-mode design
    /// decision #9) — pure rename, no behavior change, no data migration (no
    /// shipped user data exists yet, see [[yamiboreader-no-data-compat]]).
    case smartManga = "SmartManga"
}

public struct ContentCoverKey: Codable, Hashable, Sendable {
    public var targetType: ContentCoverTargetType
    public var targetID: String

    public init(targetType: ContentCoverTargetType, targetID: String) {
        self.targetType = targetType
        self.targetID = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func thread(tid: String) -> ContentCoverKey {
        ContentCoverKey(targetType: .thread, targetID: tid)
    }

    public static func smartManga(cleanBookName: String) -> ContentCoverKey {
        ContentCoverKey(targetType: .smartManga, targetID: cleanBookName)
    }

    /// Canonical cover key for a reading-progress target. Normal and novel
    /// threads share the `.thread` key: how a thread reads is presentation,
    /// not content identity.
    public init?(target: FavoriteContentTarget) {
        switch target.kind {
        case .normalThread, .novelThread, .mangaThread:
            guard let threadID = target.threadID else { return nil }
            self = .thread(tid: threadID)
        case .mangaTitle:
            guard let cleanBookName = target.mangaCleanBookName else { return nil }
            self = .smartManga(cleanBookName: cleanBookName)
        }
    }

    /// Canonical cover key for a favorite target. Every `FavoriteItemTarget`
    /// case is thread-based (there is no merged-directory identity on this
    /// type at all), so a favorite's own cover key is always `.thread(tid:)`
    /// — including for `.mangaThread` favorites. Card-level cover reads and
    /// writes must NOT call this directly: a resolved-directory smart card's
    /// cover lives under the shared `.smartManga` key instead, and
    /// `FavoriteCardProjection.contentCoverKey` is the one place that picks
    /// between the two (smart-comic-mode decision #13/#16).
    public init?(target: FavoriteItemTarget) {
        guard let threadID = target.threadID else { return nil }
        self = .thread(tid: threadID)
    }
}

public struct ContentCover: Codable, Hashable, Sendable {
    public var key: ContentCoverKey
    public var automaticCoverURL: URL?
    public var manualCoverURL: URL?
    public var dynamicEnabled: Bool
    /// User override that suppresses both cover URLs in favor of the text
    /// placeholder, independent of `dynamicEnabled`/which URL would
    /// otherwise resolve. Cleared whenever an explicit image-cover action
    /// (manual set or restore-to-automatic) runs, since those represent the
    /// user asking for an image again.
    public var textCoverForced: Bool
    public var updatedAt: Date

    public init(
        key: ContentCoverKey,
        automaticCoverURL: URL? = nil,
        manualCoverURL: URL? = nil,
        dynamicEnabled: Bool = true,
        textCoverForced: Bool = false,
        updatedAt: Date = .now
    ) {
        self.key = key
        self.automaticCoverURL = automaticCoverURL
        self.manualCoverURL = manualCoverURL
        self.dynamicEnabled = dynamicEnabled
        self.textCoverForced = textCoverForced
        self.updatedAt = updatedAt
    }

    public var resolvedURL: URL? {
        guard !textCoverForced else { return nil }
        if dynamicEnabled {
            return automaticCoverURL ?? manualCoverURL
        } else {
            return manualCoverURL ?? automaticCoverURL
        }
    }
}

public actor ContentCoverStore {
    public static let didChangeNotification = Notification.Name("yamibox.contentCoverStore.didChange")
    public static let changeIDUserInfoKey = "changeID"
    public nonisolated let changeID = UUID().uuidString

    private let database: DatabasePool

    public init(databasePool: DatabasePool? = nil) {
        self.database = databasePool ?? Self.openDatabase()
    }

    /// Isolated-storage convenience mirroring `FavoriteLibraryStore`: standard
    /// defaults use the shared database, any other suite gets its own pool in
    /// a temporary directory (tests and previews).
    public init(defaults: UserDefaults, key: String = "yamibox.contentCovers") {
        self.database = Self.openDatabase(defaults: defaults, key: key)
    }

    public func cover(for key: ContentCoverKey) async -> ContentCover? {
        guard !key.targetID.isEmpty else { return nil }
        do {
            return try await database.read { db in
                try Self.fetchCover(for: key, in: db)
            }
        } catch {
            YamiboLog.library.warning("Failed to read content cover for key \(key.targetID, privacy: .public): \(error)")
            return nil
        }
    }

    /// Batch lookup for list surfaces (the browsing-history page): one read
    /// transaction instead of one actor round-trip per row. Keys without a
    /// stored cover are simply absent from the result.
    public func covers(for keys: [ContentCoverKey]) async -> [ContentCoverKey: ContentCover] {
        let validKeys = Array(Set(keys.filter { !$0.targetID.isEmpty }))
        guard !validKeys.isEmpty else { return [:] }
        do {
            return try await database.read { db in
                var covers: [ContentCoverKey: ContentCover] = [:]
                // 200 keys * 2 bind parameters stays well under SQLite's
                // 999-parameter limit.
                for chunk in stride(from: 0, to: validKeys.count, by: 200).map({ Array(validKeys[$0..<min($0 + 200, validKeys.count)]) }) {
                    let condition = Array(repeating: "(target_type = ? AND target_id = ?)", count: chunk.count)
                        .joined(separator: " OR ")
                    let arguments = chunk.flatMap { [$0.targetType.rawValue, $0.targetID] }
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT target_type, target_id, automatic_url, manual_url, dynamic_enabled, text_cover_forced, updated_at
                        FROM content_cover
                        WHERE \(condition)
                        """,
                        arguments: StatementArguments(arguments)
                    )
                    for row in rows {
                        guard let targetType = ContentCoverTargetType(rawValue: row["target_type"] as String) else { continue }
                        let key = ContentCoverKey(targetType: targetType, targetID: row["target_id"])
                        covers[key] = ContentCover(
                            key: key,
                            automaticCoverURL: (row["automatic_url"] as String?).flatMap(URL.init(string:)),
                            manualCoverURL: (row["manual_url"] as String?).flatMap(URL.init(string:)),
                            dynamicEnabled: row["dynamic_enabled"],
                            textCoverForced: row["text_cover_forced"],
                            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                        )
                    }
                }
                return covers
            }
        } catch {
            YamiboLog.library.warning("Failed to batch-read \(validKeys.count) content covers: \(error)")
            return [:]
        }
    }

    @discardableResult
    public func setAutomaticCover(_ url: URL, for key: ContentCoverKey, date: Date = .now) async throws -> Bool {
        guard let normalizedURL = Self.normalizedCoverURL(from: url.absoluteString),
              !key.targetID.isEmpty else {
            return false
        }
        try await database.write { db in
            var cover = try Self.fetchCover(for: key, in: db) ?? ContentCover(key: key)
            cover.automaticCoverURL = normalizedURL
            cover.updatedAt = date
            try Self.upsert(cover, in: db)
        }
        postChangeNotification()
        return true
    }

    @discardableResult
    public func setManualCover(_ url: URL, for key: ContentCoverKey, date: Date = .now) async throws -> Bool {
        guard let normalizedURL = Self.normalizedCoverURL(from: url.absoluteString),
              !key.targetID.isEmpty else {
            return false
        }
        try await database.write { db in
            var cover = try Self.fetchCover(for: key, in: db) ?? ContentCover(key: key)
            cover.manualCoverURL = normalizedURL
            cover.dynamicEnabled = false
            cover.textCoverForced = false
            cover.updatedAt = date
            try Self.upsert(cover, in: db)
        }
        postChangeNotification()
        return true
    }

    /// Reverts the target to automatic covers: drops the manual URL and turns
    /// dynamic mode back on.
    @discardableResult
    public func clearManualCover(for key: ContentCoverKey, date: Date = .now) async throws -> Bool {
        guard !key.targetID.isEmpty else { return false }
        let didClear = try await database.write { db in
            guard var cover = try Self.fetchCover(for: key, in: db), cover.manualCoverURL != nil else {
                return false
            }
            cover.manualCoverURL = nil
            cover.dynamicEnabled = true
            cover.textCoverForced = false
            cover.updatedAt = date
            try Self.upsert(cover, in: db)
            return true
        }
        if didClear {
            postChangeNotification()
        }
        return didClear
    }

    public func setDynamicEnabled(_ enabled: Bool, for key: ContentCoverKey, date: Date = .now) async throws {
        guard !key.targetID.isEmpty else { return }
        try await database.write { db in
            var cover = try Self.fetchCover(for: key, in: db) ?? ContentCover(key: key)
            cover.dynamicEnabled = enabled
            cover.updatedAt = date
            try Self.upsert(cover, in: db)
        }
        postChangeNotification()
    }

    /// Toggles the text-placeholder override on or off. Unlike
    /// `setManualCover`/`clearManualCover`, this never touches the stored
    /// automatic/manual URLs, so un-forcing resolves back to whatever those
    /// would already have produced.
    @discardableResult
    public func setTextCoverForced(_ forced: Bool, for key: ContentCoverKey, date: Date = .now) async throws -> Bool {
        guard !key.targetID.isEmpty else { return false }
        try await database.write { db in
            var cover = try Self.fetchCover(for: key, in: db) ?? ContentCover(key: key)
            cover.textCoverForced = forced
            cover.updatedAt = date
            try Self.upsert(cover, in: db)
        }
        postChangeNotification()
        return true
    }

    public func clearAll() async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM content_cover")
        }
        postChangeNotification()
    }

    public func totalDiskUsageBytes() async -> Int {
        do {
            return try await database.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COALESCE(SUM(
                        length(CAST(target_type AS BLOB)) +
                        length(CAST(target_id AS BLOB)) +
                        COALESCE(length(CAST(automatic_url AS BLOB)), 0) +
                        COALESCE(length(CAST(manual_url AS BLOB)), 0) +
                        24
                    ), 0)
                    FROM content_cover
                    """
                ) ?? 0
            }
        } catch {
            YamiboLog.library.warning("Failed to read content cover disk usage: \(error)")
            return 0
        }
    }

    public static func normalizedCoverURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lowercased = value.lowercased()
        guard !lowercased.hasPrefix("data:"),
              !lowercased.hasPrefix("blob:"),
              !lowercased.contains("none.gif"),
              !lowercased.contains("static/image/"),
              !lowercased.contains("/smiley/"),
              !lowercased.contains("/face/") else {
            return nil
        }

        if lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://") {
            return URL(string: value)
        }
        if value.hasPrefix("//") {
            return URL(string: "https:\(value)")
        }
        return YamiboDomain.url(forSitePath: value)
    }

    /// Moves a smart-manga cover row to a renamed directory inside the
    /// caller's transaction, so directory renames keep their cover atomically.
    static func renameSmartMangaCover(from oldName: String, to newName: String, in db: Database) throws {
        let oldKey = ContentCoverKey.smartManga(cleanBookName: oldName)
        let newKey = ContentCoverKey.smartManga(cleanBookName: newName)
        guard !oldKey.targetID.isEmpty, !newKey.targetID.isEmpty, oldKey != newKey else { return }
        guard var cover = try fetchCover(for: oldKey, in: db) else { return }
        // The renamed directory may already have a row; the moved row wins only
        // if the destination is empty.
        if try fetchCover(for: newKey, in: db) == nil {
            cover.key = newKey
            try upsert(cover, in: db)
        }
        try db.execute(
            sql: "DELETE FROM content_cover WHERE target_type = ? AND target_id = ?",
            arguments: [oldKey.targetType.rawValue, oldKey.targetID]
        )
    }

    private static func fetchCover(for key: ContentCoverKey, in db: Database) throws -> ContentCover? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT automatic_url, manual_url, dynamic_enabled, text_cover_forced, updated_at
            FROM content_cover
            WHERE target_type = ? AND target_id = ?
            """,
            arguments: [key.targetType.rawValue, key.targetID]
        ) else {
            return nil
        }
        return ContentCover(
            key: key,
            automaticCoverURL: (row["automatic_url"] as String?).flatMap(URL.init(string:)),
            manualCoverURL: (row["manual_url"] as String?).flatMap(URL.init(string:)),
            dynamicEnabled: row["dynamic_enabled"],
            textCoverForced: row["text_cover_forced"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    private static func upsert(_ cover: ContentCover, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO content_cover
            (target_type, target_id, automatic_url, manual_url, dynamic_enabled, text_cover_forced, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cover.key.targetType.rawValue,
                cover.key.targetID,
                cover.automaticCoverURL?.absoluteString,
                cover.manualCoverURL?.absoluteString,
                cover.dynamicEnabled,
                cover.textCoverForced,
                cover.updatedAt.timeIntervalSince1970,
            ]
        )
    }

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }

    private static func openDatabase() -> DatabasePool {
        do {
            return try YamiboDatabase.openPool()
        } catch {
            fatalError("Failed to open ContentCoverStore database: \(error)")
        }
    }

    private static func openDatabase(defaults: UserDefaults, key: String) -> DatabasePool {
        do {
            if defaults === UserDefaults.standard {
                return try YamiboDatabase.openPool()
            }
            let idKey = "\(key).grdbDatabaseID"
            let databaseID: String
            if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
                databaseID = existing
            } else {
                databaseID = UUID().uuidString
                defaults.set(databaseID, forKey: idKey)
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("yamibo-x-content-covers", isDirectory: true)
                .appendingPathComponent(databaseID, isDirectory: true)
            return try YamiboDatabase.openPool(rootDirectory: root)
        } catch {
            fatalError("Failed to open ContentCoverStore database: \(error)")
        }
    }
}

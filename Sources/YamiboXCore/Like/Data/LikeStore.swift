import Foundation
@preconcurrency import GRDB

/// Result of `upsertTextLike`: the stored (possibly merged) item plus the ids
/// of any existing text Like Items it subsumed, so callers can drop stale
/// highlights for those ids.
public struct LikeTextUpsertResult: Hashable, Sendable {
    public var item: LikeItem
    public var replacedIDs: [String]

    public init(item: LikeItem, replacedIDs: [String]) {
        self.item = item
        self.replacedIDs = replacedIDs
    }
}

/// Persists the local-first Like Library: liked text excerpts and images,
/// independent of the Favorite Library. Liking never requires or creates a
/// favorite, and deleting a favorite never deletes Like Items.
public actor LikeStore {
    public static let didChangeNotification = Notification.Name("yamibox.likeStore.didChange")
    public static let changeIDUserInfoKey = "changeID"
    public nonisolated let changeID = UUID().uuidString

    private let database: DatabasePool

    public init(databasePool: DatabasePool? = nil) {
        self.database = databasePool ?? Self.openDatabase()
    }

    /// Isolated-storage convenience mirroring `ContentCoverStore`: standard
    /// defaults use the shared database, any other suite gets its own pool in
    /// a temporary directory (tests and previews).
    public init(defaults: UserDefaults, key: String = "yamibox.likeStore") {
        self.database = Self.openDatabase(defaults: defaults, key: key)
    }

    public func like(id: String) async -> LikeItem? {
        try? await database.read { db in try Self.fetchLike(id: id, in: db) }
    }

    public func likes(for workKey: LikeWorkKey) async -> [LikeItem] {
        (try? await database.read { db in try Self.fetchLikes(workKey: workKey, in: db) }) ?? []
    }

    /// Work-level rows for the My Likes first level, ordered by most recent
    /// like activity.
    public func workSummaries() async -> [LikeWorkSummary] {
        (try? await database.read { db in try Self.fetchWorkSummaries(in: db) }) ?? []
    }

    /// Adds a text Like Item, merging it with any existing text Like Items in
    /// the same chapter whose ranges overlap or touch the new range. The
    /// caller is responsible for re-capturing `excerptText` over the union
    /// range before calling this; the replaced items are deleted here.
    @discardableResult
    public func upsertTextLike(
        id: String = UUID().uuidString,
        workKey: LikeWorkKey,
        anchor: NovelTextLikeAnchor,
        excerptText: String,
        date: Date = .now
    ) async throws -> LikeTextUpsertResult {
        do {
            let result = try await database.write { db -> LikeTextUpsertResult in
                let existing = try Self.fetchLikes(workKey: workKey, kind: .text, in: db)
                var replacedIDs: [String] = []
                for candidate in existing where candidate.id != id {
                    guard case let .novelText(candidateAnchor) = candidate.anchor,
                          NovelLikeTextEndpointOrdering.overlapsOrTouches(candidateAnchor, anchor) else {
                        continue
                    }
                    replacedIDs.append(candidate.id)
                }
                for replacedID in replacedIDs {
                    try Self.deleteRow(id: replacedID, in: db)
                }
                let createdAt = try Self.fetchLike(id: id, in: db)?.createdAt ?? date
                let item = LikeItem(
                    id: id,
                    workKey: workKey,
                    kind: .text,
                    excerptText: excerptText,
                    anchor: .novelText(anchor),
                    createdAt: createdAt,
                    updatedAt: date
                )
                try Self.upsertRow(item, in: db)
                return LikeTextUpsertResult(item: item, replacedIDs: replacedIDs)
            }
            postChangeNotification()
            return result
        } catch let error as YamiboError {
            throw error
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Adds or replaces an image Like Item (novel illustration or manga page).
    /// Image bytes are stored separately by `LikeImageStore`; this only
    /// persists the metadata row.
    @discardableResult
    public func upsertImageLike(
        id: String = UUID().uuidString,
        workKey: LikeWorkKey,
        anchor: LikeAnchorPayload,
        sourceImageURL: URL?,
        date: Date = .now
    ) async throws -> LikeItem {
        do {
            let item = try await database.write { db -> LikeItem in
                let createdAt = try Self.fetchLike(id: id, in: db)?.createdAt ?? date
                let item = LikeItem(
                    id: id,
                    workKey: workKey,
                    kind: .image,
                    sourceImageURL: sourceImageURL,
                    anchor: anchor,
                    createdAt: createdAt,
                    updatedAt: date
                )
                try Self.upsertRow(item, in: db)
                return item
            }
            postChangeNotification()
            return item
        } catch let error as YamiboError {
            throw error
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Soft-deletes an item (WebDAV tombstone, ADR-0049): the row stays, marked
    /// `deleted_at`, so it disappears from every read below but a stale remote
    /// snapshot can't resurrect it on merge.
    public func delete(id: String, date: Date = .now) async throws {
        do {
            try await database.write { db in try Self.softDeleteRow(id: id, date: date, in: db) }
            postChangeNotification()
        } catch let error as YamiboError {
            throw error
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Soft-deletes several items in one write transaction (multi-select
    /// batch delete on the My Likes list screens).
    public func delete(ids: [String], date: Date = .now) async throws {
        guard !ids.isEmpty else { return }
        do {
            try await database.write { db in
                for id in ids {
                    try Self.softDeleteRow(id: id, date: date, in: db)
                }
            }
            postChangeNotification()
        } catch let error as YamiboError {
            throw error
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Every Like Item including soft-deleted rows, for WebDAV export.
    public func allIncludingDeleted() async -> [LikeItem] {
        (try? await database.read { db in try Self.fetchAllIncludingDeleted(in: db) }) ?? []
    }

    /// Replaces the entire local Like Library with a WebDAV-merged snapshot.
    /// Items may carry `deletedAt` to persist a tombstone alongside its known
    /// data; the merge/export logic that builds this array lives in
    /// `LikeLibraryWebDAVParticipant`, not here.
    public func replaceAll(_ items: [LikeItem]) async throws {
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM like_items")
                for item in items {
                    try Self.upsertRow(item, in: db)
                }
            }
            postChangeNotification()
        } catch let error as YamiboError {
            throw error
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    public func deleteAll(workKey: LikeWorkKey) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM like_items WHERE work_kind = ? AND work_id = ?",
                    arguments: [workKey.kind.rawValue, workKey.id]
                )
            }
            postChangeNotification()
        } catch let error as YamiboError {
            throw error
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    public func clearAll() async throws {
        do {
            try await database.write { db in try db.execute(sql: "DELETE FROM like_items") }
            postChangeNotification()
        } catch let error as YamiboError {
            throw error
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }

    private static func fetchLike(id: String, in db: Database) throws -> LikeItem? {
        guard let row = try Row.fetchOne(
            db,
            sql: Self.selectColumns + " WHERE id = ? AND deleted_at IS NULL",
            arguments: [id]
        ) else {
            return nil
        }
        return try Self.item(from: row)
    }

    private static func fetchLikes(workKey: LikeWorkKey, in db: Database) throws -> [LikeItem] {
        try Row.fetchAll(
            db,
            sql: Self.selectColumns
                + " WHERE work_kind = ? AND work_id = ? AND deleted_at IS NULL ORDER BY created_at ASC, id ASC",
            arguments: [workKey.kind.rawValue, workKey.id]
        ).compactMap { try Self.item(from: $0) }
    }

    private static func fetchLikes(workKey: LikeWorkKey, kind: LikeItemKind, in db: Database) throws -> [LikeItem] {
        try Row.fetchAll(
            db,
            sql: Self.selectColumns
                + " WHERE work_kind = ? AND work_id = ? AND kind = ? AND deleted_at IS NULL ORDER BY created_at ASC, id ASC",
            arguments: [workKey.kind.rawValue, workKey.id, kind.rawValue]
        ).compactMap { try Self.item(from: $0) }
    }

    private static func fetchAllIncludingDeleted(in db: Database) throws -> [LikeItem] {
        try Row.fetchAll(
            db,
            sql: Self.selectColumns + " ORDER BY created_at ASC, id ASC"
        ).compactMap { try Self.item(from: $0) }
    }

    private static func fetchWorkSummaries(in db: Database) throws -> [LikeWorkSummary] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT work_kind, work_id, COUNT(*) AS item_count, MAX(updated_at) AS last_liked_at
            FROM like_items
            WHERE deleted_at IS NULL
            GROUP BY work_kind, work_id
            ORDER BY last_liked_at DESC
            """
        ).compactMap { row -> LikeWorkSummary? in
            guard let kind = LikeWorkKind(rawValue: row["work_kind"] as String) else { return nil }
            return LikeWorkSummary(
                workKey: LikeWorkKey(kind: kind, id: row["work_id"]),
                itemCount: row["item_count"],
                lastLikedAt: Date(timeIntervalSince1970: row["last_liked_at"])
            )
        }
    }

    private static func upsertRow(_ item: LikeItem, in db: Database) throws {
        let anchorData = try JSONEncoder().encode(item.anchor)
        guard let anchorJSON = String(data: anchorData, encoding: .utf8) else {
            throw YamiboError.persistenceFailed("Unable to encode Like anchor")
        }
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO like_items
            (id, work_kind, work_id, kind, excerpt_text, source_image_url, anchor_json, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                item.id,
                item.workKey.kind.rawValue,
                item.workKey.id,
                item.kind.rawValue,
                item.excerptText,
                item.sourceImageURL?.absoluteString,
                anchorJSON,
                item.createdAt.timeIntervalSince1970,
                item.updatedAt.timeIntervalSince1970,
                item.deletedAt?.timeIntervalSince1970,
            ]
        )
    }

    private static func deleteRow(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM like_items WHERE id = ?", arguments: [id])
    }

    private static func softDeleteRow(id: String, date: Date, in db: Database) throws {
        try db.execute(
            sql: "UPDATE like_items SET deleted_at = ?, updated_at = ? WHERE id = ?",
            arguments: [date.timeIntervalSince1970, date.timeIntervalSince1970, id]
        )
    }

    static func renameMangaTitleLikes(from oldName: String, to newName: String, in db: Database) throws {
        guard oldName != newName else { return }
        try db.execute(
            sql: "UPDATE like_items SET work_id = ? WHERE work_kind = ? AND work_id = ?",
            arguments: [newName, LikeWorkKind.manga.rawValue, oldName]
        )
    }

    private static func item(from row: Row) throws -> LikeItem? {
        guard let anchorData = (row["anchor_json"] as String).data(using: .utf8),
              let anchor = try? JSONDecoder().decode(LikeAnchorPayload.self, from: anchorData),
              let workKind = LikeWorkKind(rawValue: row["work_kind"] as String),
              let kind = LikeItemKind(rawValue: row["kind"] as String) else {
            return nil
        }
        return LikeItem(
            id: row["id"],
            workKey: LikeWorkKey(kind: workKind, id: row["work_id"]),
            kind: kind,
            excerptText: row["excerpt_text"],
            sourceImageURL: (row["source_image_url"] as String?).flatMap(URL.init(string:)),
            anchor: anchor,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            deletedAt: (row["deleted_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }

    private static let selectColumns = """
    SELECT id, work_kind, work_id, kind, excerpt_text, source_image_url, anchor_json, created_at, updated_at, deleted_at
    FROM like_items
    """

    private static func openDatabase() -> DatabasePool {
        do {
            return try YamiboDatabase.openPool()
        } catch {
            fatalError("Failed to open LikeStore database: \(error)")
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
                .appendingPathComponent("yamibo-x-like-store", isDirectory: true)
                .appendingPathComponent(databaseID, isDirectory: true)
            return try YamiboDatabase.openPool(rootDirectory: root)
        } catch {
            fatalError("Failed to open LikeStore database: \(error)")
        }
    }
}

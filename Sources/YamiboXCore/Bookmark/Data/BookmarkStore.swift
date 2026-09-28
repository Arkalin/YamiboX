import Foundation
@preconcurrency import GRDB

/// Persists the local-first Bookmark Library: user-placed position markers,
/// independent of both the Favorite Library and the Like Library.
///
/// Bookmarks are pure navigation: no content, no image bytes, and no relation
/// to the automatically saved reading position.
public actor BookmarkStore: ReaderBookmarkMutating {
    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let database: DatabasePool

    public init(databasePool: DatabasePool? = nil) {
        self.database = databasePool
            ?? YamiboDatabasePoolResolver.resolvePool(defaults: .standard, key: "yamibox.bookmarkStore")
    }

    /// Isolated-storage convenience mirroring `LikeStore`: standard defaults
    /// use the shared database, any other suite gets its own pool in a
    /// temporary directory (tests and previews).
    public init(defaults: UserDefaults, key: String = "yamibox.bookmarkStore") {
        self.database = YamiboDatabasePoolResolver.resolvePool(defaults: defaults, key: key)
    }

    /// Every live bookmark for one work, in book order.
    public func bookmarks(for workKey: ReadingWorkKey) async throws -> [BookmarkItem] {
        try await database.read { db in try Self.fetchBookmarks(workKey: workKey, in: db) }
    }

    public func count(for workKey: ReadingWorkKey) async throws -> Int {
        let fetched = try await database.read { db -> Int? in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM bookmarks WHERE work_kind = ? AND work_id = ? AND deleted_at IS NULL",
                arguments: [workKey.kind.rawValue, try MangaDirectoryIdentityDatabase.canonicalWorkID(workKey, in: db)]
            )
        }
        return fetched ?? 0
    }

    /// The live bookmark that already marks the place `anchor` points at, if
    /// any. This is the whole of the toggle's "is the current position already
    /// bookmarked" test — see `NovelBookmarkAnchor.neighborhoodCharacterRadius`
    /// for why the novel neighborhood is deliberately narrow.
    public func bookmark(marking anchor: BookmarkAnchorPayload, in workKey: ReadingWorkKey) async throws -> BookmarkItem? {
        try await bookmarks(for: workKey).first { $0.anchor.marksSamePlace(as: anchor) }
    }

    /// Adds a bookmark at `anchor`, or removes the one already marking that
    /// place. Idempotent by position: a place holds at most one bookmark, so
    /// pressing the button twice always returns to the starting state.
    @discardableResult
    public func toggle(
        workKey: ReadingWorkKey,
        anchor: BookmarkAnchorPayload,
        excerptText: String? = nil,
        date: Date = .now
    ) async throws -> BookmarkToggleOutcome {
        return try await StoreWriteTransaction.perform(in: database, notifying: changeBroadcaster) { db -> BookmarkToggleOutcome in
            let existing = try Self.fetchBookmarks(workKey: workKey, in: db)
            if let match = existing.first(where: { $0.anchor.marksSamePlace(as: anchor) }) {
                try Self.softDeleteRow(id: match.id, date: date, in: db)
                var removed = match
                removed.deletedAt = date
                removed.updatedAt = date
                return .removed(removed)
            }
            let item = BookmarkItem(
                workKey: workKey,
                anchor: anchor,
                excerptText: excerptText,
                sortKey: ReaderAnnotationSortKey.of(anchor),
                createdAt: date,
                updatedAt: date
            )
            try Self.upsertRow(item, in: db)
            return .added(item)
        }
    }

    /// Soft-deletes a bookmark (WebDAV tombstone): the row stays, marked
    /// `deleted_at`, so a stale remote snapshot cannot resurrect it on merge.
    public func delete(id: String, date: Date = .now) async throws {
        try await delete(ids: [id], date: date)
    }

    public func delete(ids: [String], date: Date = .now) async throws {
        guard !ids.isEmpty else { return }
        try await StoreWriteTransaction.perform(in: database, notifying: changeBroadcaster) { db in
            for id in ids {
                try Self.softDeleteRow(id: id, date: date, in: db)
            }
        }
    }

    /// Every bookmark including soft-deleted rows, for WebDAV export.
    public func allIncludingDeleted() async throws -> [BookmarkItem] {
        try await database.read { db in try Self.fetchAllIncludingDeleted(in: db) }
    }

    /// Replaces the entire local Bookmark Library with a WebDAV-merged
    /// snapshot. Items may carry `deletedAt` to persist a tombstone alongside
    /// their known data; the merge logic lives in
    /// `BookmarkLibraryWebDAVParticipant`, not here.
    public func replaceAll(_ items: [BookmarkItem]) async throws {
        try await StoreWriteTransaction.perform(in: database, notifying: changeBroadcaster) { db in
            try db.execute(sql: "DELETE FROM bookmarks")
            for item in items {
                try Self.upsertRow(item, in: db)
            }
        }
    }

    public func deleteAll(workKey: ReadingWorkKey, date: Date = .now) async throws {
        try await StoreWriteTransaction.perform(in: database, notifying: changeBroadcaster) { db in
            let ids = try String.fetchAll(db,
                sql: "SELECT id FROM bookmarks WHERE work_kind = ? AND work_id = ? AND deleted_at IS NULL",
                arguments: [workKey.kind.rawValue, try MangaDirectoryIdentityDatabase.canonicalWorkID(workKey, in: db)]
            )
            for id in ids { try Self.softDeleteRow(id: id, date: date, in: db) }
        }
    }

    public func clearAll() async throws {
        try await StoreWriteTransaction.perform(in: database, notifying: changeBroadcaster) { db in
            try db.execute(sql: "DELETE FROM bookmarks")
            try db.execute(sql: "DELETE FROM bookmark_sync_state")
        }
    }

    func syncSnapshot() async throws -> SyncRecordSnapshot<BookmarkItem> {
        try await database.read { db in try Self.syncSnapshot(in: db) }
    }

    private static func syncSnapshot(in db: Database) throws -> SyncRecordSnapshot<BookmarkItem> {
        let records = try Self.fetchAllIncludingDeleted(in: db)
        var deletions = try SyncDeletionState.load(from: "bookmark_sync_state", in: db)
        for record in records {
            if let date = record.deletedAt { deletions.recordDeletion(of: record.id, at: date) }
        }
        return SyncRecordSnapshot(records: records, deletions: deletions)
    }

    @discardableResult
    func updateSyncSnapshot<T: Sendable>(
        _ transform: @escaping @Sendable (inout SyncRecordSnapshot<BookmarkItem>) throws -> T
    ) async throws -> T {
        let result = try await database.write { db in
            var snapshot = try Self.syncSnapshot(in: db)
            let result = try transform(&snapshot)
            try db.execute(sql: "DELETE FROM bookmarks")
            for record in snapshot.records { try Self.upsertRow(record, in: db) }
            try snapshot.deletions.save(to: "bookmark_sync_state", in: db)
            return result
        }
        postChangeNotification()
        return result
    }

    public nonisolated func notifyIdentityMigrationCommitted() { postChangeNotification() }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }

    private static let selectColumns = """
    SELECT id, work_kind, work_id, anchor_json, excerpt_text, sort_key, created_at, updated_at, deleted_at
    FROM bookmarks
    """

    private static func fetchBookmarks(workKey: ReadingWorkKey, in db: Database) throws -> [BookmarkItem] {
        try Row.fetchAll(
            db,
            sql: selectColumns
                + " WHERE work_kind = ? AND work_id = ? AND deleted_at IS NULL ORDER BY sort_key ASC, created_at ASC, id ASC",
            arguments: [workKey.kind.rawValue, try MangaDirectoryIdentityDatabase.canonicalWorkID(workKey, in: db)]
        ).compactMap { try Self.item(from: $0) }
    }

    private static func fetchAllIncludingDeleted(in db: Database) throws -> [BookmarkItem] {
        try Row.fetchAll(
            db,
            sql: selectColumns + " ORDER BY created_at ASC, id ASC"
        ).map {
            guard let item = try Self.item(from: $0) else {
                throw YamiboPersistenceError(context: "Invalid bookmark row")
            }
            return item
        }
    }

    private static func upsertRow(_ item: BookmarkItem, in db: Database) throws {
        let anchorData = try JSONEncoder().encode(item.anchor)
        guard let anchorJSON = String(data: anchorData, encoding: .utf8) else {
            throw YamiboPersistenceError(context: "Unable to encode bookmark anchor")
        }
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO bookmarks
            (id, work_kind, work_id, anchor_json, excerpt_text, sort_key, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                item.id,
                item.workKey.kind.rawValue,
                try MangaDirectoryIdentityDatabase.canonicalWorkID(item.workKey, in: db),
                anchorJSON,
                item.excerptText,
                item.sortKey,
                item.createdAt.timeIntervalSince1970,
                item.updatedAt.timeIntervalSince1970,
                item.deletedAt?.timeIntervalSince1970,
            ]
        )
    }

    private static func softDeleteRow(id: String, date: Date, in db: Database) throws {
        var deletions = try SyncDeletionState.load(from: "bookmark_sync_state", in: db)
        deletions.recordDeletion(of: id, at: date)
        try deletions.save(to: "bookmark_sync_state", in: db)
        try db.execute(
            sql: "UPDATE bookmarks SET deleted_at = ?, updated_at = ? WHERE id = ?",
            arguments: [date.timeIntervalSince1970, date.timeIntervalSince1970, id]
        )
    }

    private static func item(from row: Row) throws -> BookmarkItem? {
        guard let anchorData = (row["anchor_json"] as String).data(using: .utf8),
              let anchor = try? JSONDecoder().decode(BookmarkAnchorPayload.self, from: anchorData),
              let workKind = ReadingWorkKind(rawValue: row["work_kind"] as String) else {
            return nil
        }
        return BookmarkItem(
            id: row["id"],
            workKey: ReadingWorkKey(kind: workKind, id: row["work_id"]),
            anchor: anchor,
            excerptText: row["excerpt_text"],
            sortKey: row["sort_key"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            deletedAt: (row["deleted_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }
}

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
    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let database: DatabasePool

    public init(databasePool: DatabasePool? = nil) {
        // `.standard` is the resolver's "shared production pool" signal, so
        // the nil-pool fallback and the convenience below stay one code path.
        self.database = databasePool
            ?? YamiboDatabasePoolResolver.resolvePool(defaults: .standard, key: "yamibox.likeStore")
    }

    /// Isolated-storage convenience mirroring `ContentCoverStore`: standard
    /// defaults use the shared database, any other suite gets its own pool in
    /// a temporary directory (tests and previews).
    public init(defaults: UserDefaults, key: String = "yamibox.likeStore") {
        self.database = YamiboDatabasePoolResolver.resolvePool(defaults: defaults, key: key)
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
        excerptPrefix: String? = nil,
        excerptSuffix: String? = nil,
        style: LikeStyle = .default,
        note: String? = nil,
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
                    // Soft, not physical. A physically deleted row is neither in
                    // `items` nor in `tombstones` on the next WebDAV export, so
                    // the remote snapshot's copy came back as an unseen new item
                    // and the merged-away highlight reappeared, overlapping the
                    // one that subsumed it.
                    try Self.softDeleteRow(id: replacedID, date: date, in: db)
                }
                let createdAt = try Self.fetchLike(id: id, in: db)?.createdAt ?? date
                let item = LikeItem(
                    id: id,
                    workKey: workKey,
                    kind: .text,
                    excerptText: excerptText,
                    excerptPrefix: excerptPrefix,
                    excerptSuffix: excerptSuffix,
                    anchor: .novelText(anchor),
                    // New style wins over every style it subsumes: the user
                    // just picked one, and the merged range is a single
                    // annotation that can only have one.
                    style: style,
                    note: note,
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
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
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
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    /// Changes an item's highlight style.
    ///
    /// Deliberately its own write path rather than a round trip through
    /// `upsertTextLike`: recolouring is not a new selection, so it must not
    /// swallow the neighbours that an overlap merge would.
    @discardableResult
    public func updateStyle(id: String, style: LikeStyle, date: Date = .now) async throws -> LikeItem? {
        do {
            let updated = try await database.write { db -> LikeItem? in
                guard var item = try Self.fetchLike(id: id, in: db) else { return nil }
                item.style = style
                item.updatedAt = date
                try Self.upsertRow(item, in: db)
                return item
            }
            if updated != nil {
                postChangeNotification()
            }
            return updated
        } catch let error as YamiboError {
            throw error
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    /// Sets or clears an item's note.
    ///
    /// Its own write path for the same reason `updateStyle` is: writing a note
    /// is not a new selection, so it must not run the overlap merge. A
    /// whitespace-only note is stored as nil, which is how clearing the editor
    /// deletes the note without deleting the annotation.
    @discardableResult
    public func updateNote(id: String, note: String?, date: Date = .now) async throws -> LikeItem? {
        let normalized = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (normalized?.isEmpty ?? true) ? nil : normalized
        do {
            let updated = try await database.write { db -> LikeItem? in
                guard var item = try Self.fetchLike(id: id, in: db) else { return nil }
                item.note = resolved
                item.updatedAt = date
                try Self.upsertRow(item, in: db)
                return item
            }
            if updated != nil {
                postChangeNotification()
            }
            return updated
        } catch let error as YamiboError {
            throw error
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
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
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
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
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
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
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
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
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    public func clearAll() async throws {
        do {
            try await database.write { db in try db.execute(sql: "DELETE FROM like_items") }
            postChangeNotification()
        } catch let error as YamiboError {
            throw error
        } catch let error as YamiboPersistenceError {
            throw error
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    /// Sharpens the book-order keys of one work's annotations once a reader
    /// session has laid a forum page out and therefore knows where each post
    /// sits on it.
    ///
    /// Deliberately does NOT touch `updated_at`: the sort key is local derived
    /// state, so bumping it would mark the whole Like dataset dirty and upload
    /// it on every reader launch. It also does not post a change notification
    /// unless a row actually moved, so a no-op resolve cannot loop the reader's
    /// store observers.
    public func resolveChapterOrdinals(
        _ ordinalsByChapterIdentity: [NovelChapterIdentity: Int],
        for workKey: LikeWorkKey
    ) async {
        guard !ordinalsByChapterIdentity.isEmpty else { return }
        let changed = (try? await database.write { db -> Bool in
            var didChange = false
            for item in try Self.fetchLikes(workKey: workKey, in: db) {
                guard let chapterIdentity = LikeSortKey.chapterIdentity(of: item.anchor),
                      let ordinal = ordinalsByChapterIdentity[chapterIdentity],
                      item.chapterOrdinal != ordinal else {
                    continue
                }
                try db.execute(
                    sql: "UPDATE like_items SET chapter_ordinal = ?, sort_key = ? WHERE id = ?",
                    arguments: [ordinal, LikeSortKey.of(item.anchor, chapterOrdinal: ordinal), item.id]
                )
                didChange = true
            }
            return didChange
        }) ?? false
        if changed {
            postChangeNotification()
        }
    }

    /// Fills in the clause context around excerpts once a reader session has
    /// the chapter text in hand — the healing path for items captured before
    /// the context fields existed, or synced from another device (the fields
    /// never travel in the WebDAV payload).
    ///
    /// Same contract as `resolveChapterOrdinals`: local derived state, so
    /// `updated_at` is deliberately untouched (bumping it would dirty the whole
    /// Like dataset on every reader launch), and the change notification only
    /// fires when a row actually gained context.
    public func resolveExcerptContexts(
        _ contextsByItemID: [String: (prefix: String?, suffix: String?)]
    ) async {
        guard !contextsByItemID.isEmpty else { return }
        let changed = (try? await database.write { db -> Bool in
            var didChange = false
            for (id, context) in contextsByItemID {
                guard let item = try Self.fetchLike(id: id, in: db),
                      item.excerptPrefix != context.prefix || item.excerptSuffix != context.suffix else {
                    continue
                }
                try db.execute(
                    sql: "UPDATE like_items SET excerpt_prefix = ?, excerpt_suffix = ? WHERE id = ?",
                    arguments: [context.prefix, context.suffix, id]
                )
                didChange = true
            }
            return didChange
        }) ?? false
        if changed {
            postChangeNotification()
        }
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
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
                + " WHERE work_kind = ? AND work_id = ? AND deleted_at IS NULL ORDER BY sort_key ASC, created_at ASC, id ASC",
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
            throw YamiboPersistenceError(context: "Unable to encode Like anchor")
        }
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO like_items
            (id, work_kind, work_id, kind, excerpt_text, excerpt_prefix, excerpt_suffix, source_image_url, anchor_json, style, note, sort_key, chapter_ordinal, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                item.id,
                item.workKey.kind.rawValue,
                item.workKey.id,
                item.kind.rawValue,
                item.excerptText,
                item.excerptPrefix,
                item.excerptSuffix,
                item.sourceImageURL?.absoluteString,
                anchorJSON,
                item.style.rawValue,
                item.note,
                // Always recomputed here rather than trusted from the caller:
                // the key is derived state, and a stale one silently reorders
                // the panel.
                LikeSortKey.of(item.anchor, chapterOrdinal: item.chapterOrdinal),
                item.chapterOrdinal,
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
            excerptPrefix: row["excerpt_prefix"],
            excerptSuffix: row["excerpt_suffix"],
            sourceImageURL: (row["source_image_url"] as String?).flatMap(URL.init(string:)),
            anchor: anchor,
            style: (row["style"] as String?).flatMap(LikeStyle.init(rawValue:)) ?? .default,
            note: row["note"],
            sortKey: row["sort_key"],
            chapterOrdinal: row["chapter_ordinal"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            deletedAt: (row["deleted_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
    }

    private static let selectColumns = """
    SELECT id, work_kind, work_id, kind, excerpt_text, excerpt_prefix, excerpt_suffix, source_image_url, anchor_json, style, note, sort_key, chapter_ordinal, created_at, updated_at, deleted_at
    FROM like_items
    """
}

import Foundation
@preconcurrency import GRDB

/// Local browsing-history timeline (`browsing_history` table).
///
/// Write cadence (browsing-history decision #5): readers `record(_:)` a full
/// entry once their content loads, then `updatePosition(...)` as the user
/// pages through — the update path is UPDATE-only, so a row the user deleted
/// mid-session stays deleted until the content is opened again.
///
/// Retention (decision #9): capped at `maxEntryCount` rows, trimmed by
/// `last_visit_time` after every insert. Purely local — never synced
/// (decision #12).
public actor BrowsingHistoryStore {
    public static let maxEntryCount = 2000

    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let database: DatabasePool

    public init(databasePool: DatabasePool? = nil) {
        self.database = databasePool ?? YamiboDatabasePoolResolver.openDefaultPool(storeName: "BrowsingHistoryStore")
    }

    /// Upserts one visit, absorbing superseded rows in the same transaction
    /// (decision #13, generalized by the PRD's compatibility note):
    /// - Single-thread entries absorb any same-tid row of a *different* kind
    ///   (e.g. a board reconfigured from normal to novel between visits).
    /// - Directory-level (`.mangaTitle`) entries absorb the single-thread
    ///   rows of every directory member, passed in as `absorbingThreadIDs`
    ///   by the caller (the manga reader has the member list in hand).
    /// - `absorbingEntryIDs` removes rows superseded by an identity change
    ///   the tid-based rules can't see — a directory-level row whose
    ///   `favoriteIdentity` drifted when the synthetic single-chapter
    ///   directory resolved into a real one (directory rows carry no
    ///   thread_id, so only their exact old id can name them).
    public func record(
        _ entry: BrowsingHistoryEntry,
        absorbingThreadIDs: [String] = [],
        absorbingEntryIDs: [String] = []
    ) async throws {
        do {
            try await database.write { db in
                if let threadID = entry.target.threadID {
                    try db.execute(
                        sql: "DELETE FROM browsing_history WHERE thread_id = ? AND id != ?",
                        arguments: [threadID, entry.id]
                    )
                }
                let absorbedTIDs = absorbingThreadIDs
                    .compactMap(\.browsingHistoryTrimmedNonEmpty)
                for chunk in Self.chunked(absorbedTIDs, size: 500) {
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                    try db.execute(
                        sql: "DELETE FROM browsing_history WHERE id != ? AND thread_id IN (\(placeholders))",
                        arguments: StatementArguments([entry.id] + chunk)
                    )
                }
                let absorbedIDs = absorbingEntryIDs
                    .compactMap(\.browsingHistoryTrimmedNonEmpty)
                    .filter { $0 != entry.id }
                for chunk in Self.chunked(absorbedIDs, size: 500) {
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                    try db.execute(
                        sql: "DELETE FROM browsing_history WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                }
                try Self.upsert(entry, in: db)
                try db.execute(
                    sql: """
                    DELETE FROM browsing_history WHERE id IN (
                        SELECT id FROM browsing_history
                        ORDER BY last_visit_time DESC, id ASC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                    arguments: [Self.maxEntryCount]
                )
            }
            postChangeNotification()
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    /// Position refresh piggybacked on debounced reading-progress saves.
    /// UPDATE-only on purpose: it never resurrects a row the user deleted,
    /// and it never needs the display metadata only the open path knows.
    public func updatePosition(
        targetID: String,
        pageIndex: Int? = nil,
        pageCount: Int? = nil,
        chapterTitle: String? = nil,
        chapterThreadID: String? = nil,
        date: Date = .now
    ) async {
        guard let targetID = targetID.browsingHistoryTrimmedNonEmpty else { return }
        do {
            let changed = try await database.write { db in
                try db.execute(
                    sql: """
                    UPDATE browsing_history SET
                        page_index = COALESCE(?, page_index),
                        page_count = COALESCE(?, page_count),
                        chapter_title = COALESCE(?, chapter_title),
                        chapter_thread_id = COALESCE(?, chapter_thread_id),
                        last_visit_time = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        pageIndex.map { max(0, $0) },
                        pageCount.map { max(1, $0) },
                        chapterTitle?.browsingHistoryTrimmedNonEmpty,
                        chapterThreadID?.browsingHistoryTrimmedNonEmpty,
                        date.timeIntervalSince1970,
                        targetID,
                    ]
                )
                return db.changesCount > 0
            }
            if changed {
                postChangeNotification()
            }
        } catch {
            YamiboLog.persistence.warning("BrowsingHistoryStore.updatePosition failed; history row keeps its previous position: \(error)")
        }
    }

    public func entries(
        category: BrowsingHistoryCategory? = nil,
        searchText: String? = nil
    ) async -> [BrowsingHistoryEntry] {
        var sql = "SELECT * FROM browsing_history"
        var conditions: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if let category {
            conditions.append("category = ?")
            arguments.append(category.rawValue)
        }
        if let searchText = searchText?.browsingHistoryTrimmedNonEmpty {
            conditions.append("title LIKE ? ESCAPE '\\'")
            arguments.append("%\(Self.escapedLikePattern(searchText))%")
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY last_visit_time DESC, id ASC"
        let statementArguments: StatementArguments = StatementArguments(arguments)
        do {
            return try await database.read { [sql, statementArguments] db in
                try Row.fetchAll(db, sql: sql, arguments: statementArguments)
                    .compactMap(Self.entry(from:))
            }
        } catch {
            YamiboLog.persistence.warning("BrowsingHistoryStore.entries failed to read; returning empty list: \(error)")
            return []
        }
    }

    public func entry(forID id: String) async -> BrowsingHistoryEntry? {
        do {
            return try await database.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM browsing_history WHERE id = ? LIMIT 1",
                    arguments: [id]
                ) else { return nil }
                return Self.entry(from: row)
            }
        } catch {
            YamiboLog.persistence.warning("BrowsingHistoryStore.entry(forID:) failed to read; treating as missing: \(error)")
            return nil
        }
    }

    public func delete(id: String) async throws {
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM browsing_history WHERE id = ?", arguments: [id])
            }
            postChangeNotification()
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    public func clearAll() async throws {
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM browsing_history")
            }
            postChangeNotification()
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    // MARK: - Row mapping

    private static func upsert(_ entry: BrowsingHistoryEntry, in db: Database) throws {
        let target = entry.target
        try db.execute(
            sql: """
            INSERT INTO browsing_history
            (
                id, target_kind, thread_id, manga_id, clean_book_name, category, title,
                forum_id, author_id, page_index, page_count, chapter_title, chapter_thread_id, last_visit_time
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                entry.id,
                target.kind.rawValue,
                target.threadID,
                target.mangaID,
                target.mangaCleanBookName,
                entry.category.rawValue,
                entry.title,
                entry.forumID,
                entry.authorID,
                entry.pageIndex,
                entry.pageCount,
                entry.chapterTitle,
                entry.chapterThreadID,
                entry.lastVisitTime.timeIntervalSince1970,
            ]
        )
    }

    private static func entry(from row: Row) -> BrowsingHistoryEntry? {
        guard let kind = FavoriteContentTargetKind(rawValue: row["target_kind"] as String),
              let target = contentTarget(
                  kind: kind,
                  threadID: row["thread_id"] as String?,
                  mangaID: row["manga_id"] as String?,
                  cleanBookName: row["clean_book_name"] as String?
              ) else {
            YamiboLog.persistence.warning("BrowsingHistoryStore dropped a browsing_history row with unparseable target, id=\(row["id"] as String? ?? "unknown", privacy: .public)")
            return nil
        }
        return BrowsingHistoryEntry(
            target: target,
            title: row["title"],
            forumID: row["forum_id"] as String?,
            authorID: row["author_id"] as String?,
            pageIndex: row["page_index"] as Int?,
            pageCount: row["page_count"] as Int?,
            chapterTitle: row["chapter_title"] as String?,
            chapterThreadID: row["chapter_thread_id"] as String?,
            lastVisitTime: Date(timeIntervalSince1970: row["last_visit_time"])
        )
    }

    private static func contentTarget(
        kind: FavoriteContentTargetKind,
        threadID: String?,
        mangaID: String?,
        cleanBookName: String?
    ) -> FavoriteContentTarget? {
        switch kind {
        case .normalThread:
            guard let threadID = threadID?.browsingHistoryTrimmedNonEmpty else { return nil }
            return .normalThread(threadID: threadID)
        case .novelThread:
            guard let threadID = threadID?.browsingHistoryTrimmedNonEmpty else { return nil }
            return .novelThread(threadID: threadID)
        case .mangaTitle:
            guard let cleanBookName = cleanBookName?.browsingHistoryTrimmedNonEmpty else { return nil }
            return FavoriteContentTarget(mangaID: mangaID ?? cleanBookName, mangaCleanBookName: cleanBookName)
        case .mangaThread:
            guard let threadID = threadID?.browsingHistoryTrimmedNonEmpty else { return nil }
            return .mangaThread(threadID: threadID)
        }
    }

    // MARK: - Helpers

    private static func escapedLikePattern(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func chunked(_ values: [String], size: Int) -> [[String]] {
        guard !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }

}

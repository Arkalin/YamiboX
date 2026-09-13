import Foundation
@preconcurrency import GRDB

/// Local browsing-history timeline (`browsing_history` table).
///
/// The shared workflow commits canonical rows atomically. Low-level record
/// and position helpers also support isolated store fixtures; application
/// readers use `BrowsingHistoryWorkflow` instead.
///
/// Retention (decision #9): capped at `maxEntryCount` rows, trimmed by
/// `last_visit_time` after every insert. Sync keeps stable visits separately
/// from this device's canonical reader-mode and progress projection.
public actor BrowsingHistoryStore {
    public static let maxEntryCount = 2000

    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let database: DatabasePool
    private let syncSettingsStore: WebDAVSyncSettingsStore
    private var deletedTargets: [String: Date] = [:]
    private var deletedThreads: [String: Date] = [:]
    private var lastClearTime = Date.distantPast

    public init(databasePool: DatabasePool? = nil, syncSettingsStore: WebDAVSyncSettingsStore = WebDAVSyncSettingsStore()) {
        self.database = databasePool ?? YamiboDatabasePoolResolver.openDefaultPool(storeName: "BrowsingHistoryStore")
        self.syncSettingsStore = syncSettingsStore
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
                let deletions = try SyncDeletionState.load(from: "browsing_history_local_deletions", in: db)
                    .merging(SyncDeletionState.load(from: "browsing_history_sync_state", in: db))
                let record = BrowsingHistorySyncRecord(entry)
                guard !deletions.containsDeletion(of: record.id, updatedAt: entry.lastVisitTime),
                      !deletions.containsDeletion(of: entry.id, updatedAt: entry.lastVisitTime) else { return }
                try Self.recordSyncVisit(entry, in: db)
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
                let changed = db.changesCount > 0
                if changed, let row = try Row.fetchOne(db, sql: "SELECT * FROM browsing_history WHERE id = ?", arguments: [targetID]),
                   let entry = Self.entry(from: row) {
                    try Self.recordSyncVisit(entry, in: db)
                }
                return changed
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
        let date = Date.now
        let synchronizesDeletion = await syncSettingsStore.load().isEnabled(.browsingHistory)
        do {
            let deletedSourceIDs = try await database.write { db in
                let entry = try Row.fetchOne(db, sql: "SELECT * FROM browsing_history WHERE id = ?", arguments: [id]).flatMap(Self.entry(from:))
                var tids = Set([entry?.lastVisitedThreadID, entry?.chapterThreadID].compactMap { $0 })
                if let name = entry?.target.mangaCleanBookName {
                    tids.formUnion(try String.fetchAll(db, sql: "SELECT tid FROM manga_directory_chapters WHERE directory_name = ?", arguments: [name]))
                }
                let records = try BrowsingHistorySyncRecord.load(in: db)
                let deleted = records.filter { $0.target.id == id || $0.threadID.map(tids.contains) == true }
                var keys = Set(deleted.map(\.id))
                keys.formUnion(tids.map { "source:\($0)" })
                keys.insert(id)
                for table in synchronizesDeletion
                    ? ["browsing_history_local_deletions", "browsing_history_sync_state"]
                    : ["browsing_history_local_deletions"] {
                    var state = try SyncDeletionState.load(from: table, in: db)
                    for key in keys { state.recordDeletion(of: key, at: date) }
                    try state.save(to: table, in: db)
                }
                try BrowsingHistorySyncRecord.save(records.filter { !keys.contains($0.id) }, in: db)
                try db.execute(sql: "DELETE FROM browsing_history WHERE id = ?", arguments: [id])
                return tids
            }
            deletedTargets[id] = date
            for tid in deletedSourceIDs { deletedThreads[tid] = date }
            postChangeNotification()
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    public func clearAll() async throws {
        try await database.write { db in try BrowsingHistoryDatabaseSchema.erase(in: db) }
        lastClearTime = .now
        deletedTargets = [:]
        deletedThreads = [:]
        postChangeNotification()
    }

    public func clearAllForSync(at date: Date = .now) async throws {
        let synchronizesDeletion = await syncSettingsStore.load().isEnabled(.browsingHistory)
        do {
            try await database.write { db in
                for table in synchronizesDeletion
                    ? ["browsing_history_local_deletions", "browsing_history_sync_state"]
                    : ["browsing_history_local_deletions"] {
                    var state = try SyncDeletionState.load(from: table, in: db)
                    state.clear(at: date)
                    try state.save(to: table, in: db)
                }
                try db.execute(sql: "DELETE FROM browsing_history")
                try db.execute(sql: "DELETE FROM browsing_history_sync_records")
            }
            lastClearTime = date
            deletedTargets = [:]
            deletedThreads = [:]
            postChangeNotification()
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    public func deletionNotice() async -> String {
        await syncSettingsStore.load().deletionNotice(for: .browsingHistory)
    }

    /// Live projection and sync visit payloads; excludes retained deletion
    /// markers, shared database indexes, WAL and free pages.
    public func estimatedDataUsageBytes() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(
                    length(CAST(id AS BLOB)) +
                    length(CAST(target_kind AS BLOB)) +
                    length(CAST(category AS BLOB)) +
                    length(CAST(title AS BLOB)) +
                    COALESCE(length(CAST(thread_id AS BLOB)), 0) +
                    COALESCE(length(CAST(manga_id AS BLOB)), 0) +
                    COALESCE(length(CAST(clean_book_name AS BLOB)), 0) +
                    COALESCE(length(CAST(forum_id AS BLOB)), 0) +
                    COALESCE(length(CAST(author_id AS BLOB)), 0) +
                    COALESCE(length(CAST(chapter_title AS BLOB)), 0) +
                    COALESCE(length(CAST(chapter_thread_id AS BLOB)), 0) +
                    COALESCE(length(CAST(last_visited_thread_id AS BLOB)), 0) +
                    COALESCE(length(CAST(last_visited_thread_title AS BLOB)), 0) +
                    8 * (1 + (page_index IS NOT NULL) + (page_count IS NOT NULL))
                ), 0) + (SELECT COALESCE(SUM(length(record) + length(CAST(id AS BLOB)) + 8), 0)
                    FROM browsing_history_sync_records) FROM browsing_history
                """) ?? 0
        }
    }

    // MARK: - Row mapping

    func snapshotEntries() async throws -> [BrowsingHistoryEntry] {
        try await database.read { db in
            try Self.snapshotEntries(in: db)
        }
    }

    /// Compare-and-swap protects asynchronous normalization from concurrent
    /// deletes or writes. Only changed rows are touched; observers see one commit.
    func canRecord(_ visit: BrowsingHistoryVisit, targetID: String) async throws -> Bool {
        guard visit.date > lastClearTime && visit.date > (deletedTargets[targetID] ?? .distantPast)
            && visit.date > (deletedThreads[visit.threadID] ?? .distantPast) else { return false }
        return try await database.read { db in
            let state = try SyncDeletionState.load(from: "browsing_history_local_deletions", in: db)
                .merging(SyncDeletionState.load(from: "browsing_history_sync_state", in: db))
            return !state.containsDeletion(of: targetID, updatedAt: visit.date)
                && !state.containsDeletion(of: "source:\(visit.threadID)", updatedAt: visit.date)
        }
    }

    func applyCanonicalEntries(
        _ entries: [BrowsingHistoryEntry], replacing expected: [BrowsingHistoryEntry],
        visit: BrowsingHistoryVisit? = nil, visitTargetID: String? = nil
    ) async throws -> Bool {
        if let visit, let visitTargetID, try await !canRecord(visit, targetID: visitTargetID) { return false }
        let applied = try await database.write { db in
            guard try Self.snapshotEntries(in: db) == expected else { return false }
            if let visit, let visitTargetID {
                let local = try SyncDeletionState.load(from: "browsing_history_local_deletions", in: db)
                let synced = try SyncDeletionState.load(from: "browsing_history_sync_state", in: db)
                let deletions = local.merging(synced)
                guard !deletions.containsDeletion(of: visitTargetID, updatedAt: visit.date),
                      !deletions.containsDeletion(of: "source:\(visit.threadID)", updatedAt: visit.date) else { return false }
                if let entry = entries.first(where: { $0.id == visitTargetID }) {
                    try Self.recordSyncVisit(entry, in: db)
                }
            }
            let retained = Array(entries.sorted(by: Self.newestFirst).prefix(Self.maxEntryCount))
            let byID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
            let oldByID = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
            for entry in expected where byID[entry.id] == nil {
                try db.execute(sql: "DELETE FROM browsing_history WHERE id = ?", arguments: [entry.id])
            }
            for entry in retained where oldByID[entry.id] != entry {
                try Self.upsert(entry, in: db)
            }
            return true
        }
        if applied, entries.sorted(by: Self.newestFirst) != expected { postChangeNotification() }
        return applied
    }

    static func snapshotEntries(in db: Database) throws -> [BrowsingHistoryEntry] {
        try Row.fetchAll(db, sql: "SELECT * FROM browsing_history ORDER BY last_visit_time DESC, id ASC")
            .map { row in
                guard let entry = Self.entry(from: row) else { throw YamiboPersistenceError(context: "Invalid browsing history row") }
                return entry
            }
    }

    private static func recordSyncVisit(_ entry: BrowsingHistoryEntry, in db: Database) throws {
        let incoming = BrowsingHistorySyncRecord(entry)
        let existing = try Data.fetchOne(db, sql: "SELECT record FROM browsing_history_sync_records WHERE id = ?", arguments: [incoming.id])
            .map { try JSONDecoder().decode(BrowsingHistorySyncRecord.self, from: $0) }
        let payload = try BrowsingHistoryWebDAVPayload(updatedAt: .distantPast,
            records: [existing, incoming].compactMap { $0 }).merging(nil)
        if let record = payload.records.first, record != existing { try record.save(in: db) }
        try db.execute(sql: """
            DELETE FROM browsing_history_sync_records WHERE id IN (
                SELECT id FROM browsing_history_sync_records ORDER BY last_visit_time DESC, id ASC LIMIT -1 OFFSET ?
            )
            """, arguments: [Self.maxEntryCount])
    }

    func syncSnapshot() async throws -> SyncRecordSnapshot<BrowsingHistorySyncRecord> {
        try await database.read { db in
            SyncRecordSnapshot(records: try BrowsingHistorySyncRecord.load(in: db),
                deletions: try SyncDeletionState.load(from: "browsing_history_sync_state", in: db))
        }
    }

    func updateSyncSnapshot<T: Sendable>(
        _ transform: @escaping @Sendable (inout SyncRecordSnapshot<BrowsingHistorySyncRecord>) throws -> T
    ) async throws -> T {
        let result = try await database.write { db in
            var snapshot = SyncRecordSnapshot(records: try BrowsingHistorySyncRecord.load(in: db),
                deletions: try SyncDeletionState.load(from: "browsing_history_sync_state", in: db))
            let previous = snapshot
            let result = try transform(&snapshot)
            snapshot.records.sort { $0.id < $1.id }
            guard snapshot != previous else { return (result, false) }
            try BrowsingHistorySyncRecord.save(snapshot.records, in: db)
            try snapshot.deletions.save(to: "browsing_history_sync_state", in: db)
            let existing = try Self.snapshotEntries(in: db)
            var byID: [String: BrowsingHistoryEntry] = [:]
            for record in snapshot.records {
                // Keep locally derived position fields until the workflow refreshes them.
                var entry = record.entry
                if let local = existing.first(where: { BrowsingHistorySyncRecord($0).id == record.id && $0.lastVisitTime == record.lastVisitTime }) {
                    entry.target = local.target
                    entry.title = local.target.mangaCleanBookName ?? record.title
                    entry.pageIndex = local.pageIndex
                    entry.pageCount = local.pageCount
                    entry.chapterTitle = local.chapterTitle
                    entry.chapterThreadID = local.chapterThreadID
                }
                if let old = byID[entry.id], !Self.newestFirst(entry, old) { continue }
                byID[entry.id] = entry
            }
            try db.execute(sql: "DELETE FROM browsing_history")
            for entry in byID.values.sorted(by: Self.newestFirst).prefix(Self.maxEntryCount) {
                try Self.upsert(entry, in: db)
            }
            return (result, true)
        }
        if result.1 { postChangeNotification() }
        return result.0
    }

    static func newestFirst(_ lhs: BrowsingHistoryEntry, _ rhs: BrowsingHistoryEntry) -> Bool {
        lhs.lastVisitTime == rhs.lastVisitTime ? lhs.id < rhs.id : lhs.lastVisitTime > rhs.lastVisitTime
    }

    private static func upsert(_ entry: BrowsingHistoryEntry, in db: Database) throws {
        let target = entry.target
        try db.execute(
            sql: """
            INSERT INTO browsing_history
            (
                id, target_kind, thread_id, manga_id, clean_book_name, category, title,
                forum_id, author_id, page_index, page_count, chapter_title, chapter_thread_id, last_visit_time,
                last_visited_thread_id, last_visited_thread_title
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                entry.lastVisitedThreadID,
                entry.lastVisitedThreadTitle,
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
            lastVisitTime: Date(timeIntervalSince1970: row["last_visit_time"]),
            lastVisitedThreadID: row["last_visited_thread_id"],
            lastVisitedThreadTitle: row["last_visited_thread_title"]
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

import Foundation
@preconcurrency import GRDB

public actor ReadingProgressStore {
    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let database: DatabasePool

    // All subscribers on this store share one query/observation. Observe
    // committed database changes, including cross-store identity migrations,
    // rather than relying on every writer to remember a manual notification.
    private lazy var snapshotObservation = ValueObservation
        .tracking { db in try Self.fetchAll(in: db) }
        .removeDuplicates()
        .shared(
            in: database,
            scheduling: .async(onQueue: DispatchQueue(label: "yamibox.readingProgress.observation")),
            extent: .whileObserved
        )

    /// Delivers an initial snapshot followed by committed changes, without a
    /// load-then-subscribe gap. Slow consumers receive the newest complete
    /// snapshot, never partial deltas that could lose a deletion or rename.
    /// Cancelling the last subscription stops the underlying database query.
    public func snapshots() -> some AsyncSequence<[ReadingProgressRecord], any Error> & Sendable {
        snapshotObservation.values(bufferingPolicy: .bufferingNewest(1))
    }

    /// Observe only this work's resume record, not the complete progress history.
    public func snapshots(threadID: String) -> some AsyncSequence<ReadingProgressRecord?, any Error> & Sendable {
        ValueObservation.tracking { db in
            try Self.fetchRecord(in: db, sql: """
                SELECT * FROM reading_progress
                WHERE (thread_id = ? OR manga_chapter_thread_id = ?) AND kind != ?
                ORDER BY updated_at DESC, id ASC LIMIT 1
                """, arguments: [threadID, threadID, ReadingProgressKind.thread.rawValue])
        }
        .removeDuplicates()
        .values(in: database, bufferingPolicy: .bufferingNewest(1))
    }

    public init(
        defaults: UserDefaults = .standard,
        key: String = "yamibox.readingProgress.records"
    ) {
        self.database = YamiboDatabasePoolResolver.resolvePool(defaults: defaults, key: key)
    }

    init(
        defaults: UserDefaults = .standard,
        key: String = "yamibox.readingProgress.records",
        databasePool: DatabasePool
    ) {
        self.database = databasePool
    }

    /// Fuzzy novel/manga lookup by tid. Deliberately excludes `.thread`
    /// rows: every consumer of this method (`LocalFavoriteOpenTargetResolver`
    /// novels, detail pages' continue-reading state, `AppContinuityWorkflow`,
    /// the novel reader's self-restore) reads `.novel`/`.manga` payloads, and
    /// a normal-thread anchor row for the same tid (e.g. written by a
    /// "查看讨论" companion view) is always the freshest row — without the
    /// exclusion it would shadow the real novel/manga record and silently
    /// kill resume. Normal-thread restore uses the precise
    /// `load(for: .normalThread(threadID:))` lookup instead.
    /// Only a missing record returns nil; a failed read must not reset resume state.
    public func load(threadID: String) async throws -> ReadingProgressRecord? {
        guard let threadID = Self.trimmedNonEmpty(threadID) else { return nil }
        return try await database.read { db in
            try Self.fetchRecord(
                in: db,
                sql: """
                SELECT * FROM reading_progress
                WHERE (thread_id = ? OR manga_chapter_thread_id = ?) AND kind != ?
                ORDER BY updated_at DESC, id ASC
                LIMIT 1
                """,
                arguments: [threadID, threadID, ReadingProgressKind.thread.rawValue]
            )
        }
    }

    public func loadAll() async throws -> [ReadingProgressRecord] {
        try await database.read { db in
            try Self.fetchAll(in: db)
        }
    }

    public func load(for target: FavoriteContentTarget) async throws -> ReadingProgressRecord? {
        try await database.read { db in
            let target = try Self.canonicalTarget(target, in: db)
            return try Self.fetchRecord(
                in: db,
                sql: "SELECT * FROM reading_progress WHERE id = ? LIMIT 1",
                arguments: [target.id]
            )
        }
    }

    public func delete(threadID: String, date: Date = .now) async throws {
        guard let threadID = Self.trimmedNonEmpty(threadID) else { return }
        try await database.write { db in
            let ids = try String.fetchAll(db,
                sql: "SELECT id FROM reading_progress WHERE thread_id = ? OR manga_chapter_thread_id = ?",
                arguments: [threadID, threadID])
            for id in ids { try Self.recordSyncDeletion(id: id, at: date, in: db) }
            try db.execute(
                sql: "DELETE FROM reading_progress WHERE thread_id = ? OR manga_chapter_thread_id = ?",
                arguments: [threadID, threadID]
            )
        }
        postChangeNotification()
    }

    public func replaceAll(_ records: [ReadingProgressRecord]) async throws {
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM reading_progress")
                var recordsByKey: [String: ReadingProgressRecord] = [:]
                for record in records {
                    var normalized = Self.normalizedRecord(record)
                    if let target = normalized.contentTarget {
                        normalized.contentTarget = try Self.canonicalTarget(target, in: db)
                    }
                    if let existing = recordsByKey[normalized.id], existing.updatedAt >= normalized.updatedAt {
                        continue
                    }
                    recordsByKey[normalized.id] = normalized
                }
                for record in recordsByKey.values {
                    try Self.upsert(record, in: db)
                }
            }
            postChangeNotification()
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    public func clearAll() async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM reading_progress")
            try db.execute(sql: "DELETE FROM reading_progress_sync_state")
        }
        postChangeNotification()
    }

    /// Estimates live row payload, not SQLite pages or retained sync deletion
    /// markers. Clearing progress does not promise to shrink the shared file.
    public func estimatedDataUsageBytes() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(
                    length(CAST(id AS BLOB)) +
                    length(CAST(target_kind AS BLOB)) +
                    length(CAST(kind AS BLOB)) +
                    COALESCE(length(CAST(thread_id AS BLOB)), 0) +
                    COALESCE(length(CAST(manga_id AS BLOB)), 0) +
                    COALESCE(length(CAST(clean_book_name AS BLOB)), 0) +
                    COALESCE(length(CAST(novel_last_chapter AS BLOB)), 0) +
                    COALESCE(length(CAST(novel_author_id AS BLOB)), 0) +
                    COALESCE(length(CAST(novel_resume_point_json AS BLOB)), 0) +
                    COALESCE(length(CAST(manga_chapter_thread_id AS BLOB)), 0) +
                    COALESCE(length(CAST(manga_last_chapter AS BLOB)), 0) +
                    COALESCE(length(CAST(thread_anchor_post_id AS BLOB)), 0) +
                    8 * (1 + (last_read_at IS NOT NULL) + (novel_last_view IS NOT NULL) +
                        (novel_max_view IS NOT NULL) + (novel_document_surface_progress_percent IS NOT NULL) +
                        (manga_chapter_view IS NOT NULL) + (manga_page_index IS NOT NULL) +
                        (manga_page_count IS NOT NULL) + (thread_last_page IS NOT NULL) +
                        (thread_page_count IS NOT NULL))
                ), 0) FROM reading_progress
                """) ?? 0
        }
    }

    public func clearAllForSync(at date: Date = .now) async throws {
        try await database.write { db in
            var deletions = try SyncDeletionState.load(from: "reading_progress_sync_state", in: db)
            deletions.clear(at: date)
            try deletions.save(to: "reading_progress_sync_state", in: db)
            try db.execute(sql: "DELETE FROM reading_progress")
        }
        postChangeNotification()
    }

    func syncSnapshot() async throws -> SyncRecordSnapshot<ReadingProgressRecord> {
        try await database.read { db in try Self.syncSnapshot(in: db) }
    }

    @discardableResult
    func updateSyncSnapshot<T: Sendable>(
        merging remote: SyncRecordSnapshot<ReadingProgressRecord>?,
        _ transform: @escaping @Sendable (inout SyncRecordSnapshot<ReadingProgressRecord>, SyncRecordSnapshot<ReadingProgressRecord>?) throws -> T
    ) async throws -> T {
        let result = try await database.write { db in
            // A directory merge can commit after WebDAV payload normalization.
            // Resolve records and tombstones together under the write lock,
            // before conflict resolution can admit a deleted record's old ID.
            let identities = try MangaDirectoryIdentityDatabase.snapshot(in: db)
            var snapshot = try Self.canonicalSnapshot(Self.syncSnapshot(in: db), identities: identities)
            let remote = try remote.map { try Self.canonicalSnapshot($0, identities: identities) }
            let result = try transform(&snapshot, remote)
            try db.execute(sql: "DELETE FROM reading_progress")
            for record in snapshot.records {
                try Self.upsert(Self.normalizedRecord(record), in: db)
            }
            try snapshot.deletions.save(to: "reading_progress_sync_state", in: db)
            return result
        }
        postChangeNotification()
        return result
    }

    private static func canonicalSnapshot(
        _ snapshot: SyncRecordSnapshot<ReadingProgressRecord>,
        identities: MangaDirectoryIdentitySnapshot
    ) throws -> SyncRecordSnapshot<ReadingProgressRecord> {
        let records = snapshot.records.map { record in
            var record = record
            if case let .mangaTitle(id, title) = record.contentTarget {
                let canonical = identities.canonicalID(id)
                record.contentTarget = .mangaTitle(
                    mangaID: canonical,
                    cleanBookName: identities.titles[canonical] ?? title
                )
            }
            return record
        }
        // Preserve unresolved legacy deletion markers and their import rules.
        let deletions = MangaIdentityDeletionRemapping.normalize(
            snapshot.deletions, identities: identities
        )
        return SyncRecordSnapshot(records: records, deletions: deletions)
    }

    private static func syncSnapshot(in db: Database) throws -> SyncRecordSnapshot<ReadingProgressRecord> {
        let records = try Row.fetchAll(db, sql: "SELECT * FROM reading_progress ORDER BY updated_at DESC, id ASC").map { row in
            guard let record = try Self.record(from: row) else {
                throw YamiboPersistenceError(context: "Invalid reading progress row")
            }
            return record
        }
        return SyncRecordSnapshot(records: records,
            deletions: try SyncDeletionState.load(from: "reading_progress_sync_state", in: db))
    }

    static func recordSyncDeletion(id: String, at date: Date, in db: Database) throws {
        var deletions = try SyncDeletionState.load(from: "reading_progress_sync_state", in: db)
        deletions.recordDeletion(of: id, at: date)
        try deletions.save(to: "reading_progress_sync_state", in: db)
    }

    /// Saves a normal thread's page + floor-anchor resume position — the
    /// first real writer `.normalThread` has ever had (browsing-history
    /// decisions #6/#7). Restored by `ForumThreadReaderViewModel` on every
    /// entrance without an explicit deep-link target (decision #8).
    @discardableResult
    public func saveNormalThread(
        threadID: String,
        page: Int,
        pageCount: Int? = nil,
        anchorPostID: String? = nil,
        date: Date = .now,
        discardingOlderUpdate: Bool = false
    ) async throws -> ReadingProgressRecord {
        guard let threadID = Self.trimmedNonEmpty(threadID) else {
            throw YamiboPersistenceError(context: "Normal thread reading progress requires a thread tid")
        }
        let record = ReadingProgressRecord(
            contentTarget: .normalThread(threadID: threadID),
            threadID: threadID,
            kind: .thread,
            updatedAt: date,
            lastReadAt: date,
            novel: nil,
            manga: nil,
            thread: ThreadReadingProgressRecord(
                lastPage: page,
                pageCount: pageCount,
                anchorPostID: anchorPostID
            )
        )
        try await save(record, discardingOlderUpdate: discardingOlderUpdate)
        return record
    }

    @discardableResult
    public func saveNovel(_ position: NovelReadingPosition, date: Date = .now, discardingOlderUpdate: Bool = false) async throws -> ReadingProgressRecord {
        let target = FavoriteContentTarget.novelThread(threadID: position.threadID)
        let record = ReadingProgressRecord(
            contentTarget: target,
            threadID: position.threadID,
            kind: .novel,
            updatedAt: date,
            lastReadAt: date,
            novel: NovelReadingProgressRecord(
                lastView: position.view,
                lastChapter: position.chapterTitle,
                authorID: position.authorID,
                novelResumePoint: position.resumePoint,
                novelMaxView: position.maxView,
                novelDocumentSurfaceProgressPercent: position.documentSurfaceProgressPercent
            ),
            manga: nil
        )
        try await save(record, discardingOlderUpdate: discardingOlderUpdate)
        return record
    }

    /// Saves manga reading progress, branching on Smart Comic Mode
    /// (smart-comic-mode design decision #15) rather than on
    /// `position.directoryName != nil` — a mode-off synthesized
    /// single-chapter pseudo-directory also produces a non-nil
    /// `directoryName`, so that signal can no longer be trusted to mean
    /// "mode is on" (see the Phase B warning in the design doc).
    ///
    /// Mode on: writes only the directory-level `.mangaTitle` record
    /// (unchanged mechanism — one row per directory, tracking the current
    /// chapter/page across the whole manga). Deliberately a single write, not
    /// a dual write into `.mangaThread` too — two dependent writes for one
    /// logical progress update is a split-brain risk if the second write
    /// never happens (e.g. the calling Task is cancelled between the two
    /// `await`s), and every mode-on reader
    /// (`LocalFavoriteOpenTargetResolver.mangaDirectoryResumeTarget`,
    /// `MangaDetailViewModel`, `AppContinuityWorkflow`'s mode-on branch)
    /// already resolves progress via `.mangaTitle`, not `.mangaThread` — so a
    /// mode-on `.mangaThread` row would have no reader. Accepted trade-off:
    /// if a board's mode is later toggled off, mode-off resume for a chapter
    /// that was only ever read while mode was on will start at page 0 rather
    /// than the last-read page, since no `.mangaThread` row was ever written
    /// for it.
    ///
    /// Mode off: writes only the `.mangaThread` record and returns it; the
    /// `.mangaTitle` record (if one exists from a prior mode-on session) is
    /// left completely untouched/stale, per decision #15.
    @discardableResult
    public func saveManga(_ position: MangaProgressReadingPosition, date: Date = .now, discardingOlderUpdate: Bool = false) async throws -> ReadingProgressRecord {
        guard position.isSmartModeEnabled else {
            return try await saveMangaThread(position, date: date, discardingOlderUpdate: discardingOlderUpdate)
        }

        let cleanBookName = position.directoryName ?? position.chapterTitle
        return try await saveMangaTitle(
            cleanBookName: cleanBookName,
            threadID: position.threadID,
            chapterThreadID: position.chapterThreadID,
            chapterView: position.chapterView,
            chapterTitle: position.chapterTitle,
            pageIndex: position.pageIndex,
            pageCount: position.pageCount,
            mangaID: position.mangaID,
            date: date,
            discardingOlderUpdate: discardingOlderUpdate
        )
    }

    /// Saves this chapter thread's own manga reading progress, independent of
    /// any directory-level `.mangaTitle` record — one upserted row per
    /// thread, mirroring the shape of `saveNovel`'s `.novelThread` record
    /// (smart-comic-mode design decision #15). Keyed by
    /// `position.chapterThreadID` (the specific chapter currently being
    /// read), not `position.threadID` (which stays fixed to whichever
    /// chapter this reader session originally launched with and can diverge
    /// from the current chapter after in-session chapter jumps) — so each
    /// chapter thread the user reads gets its own independent row.
    @discardableResult
    public func saveMangaThread(_ position: MangaProgressReadingPosition, date: Date = .now, discardingOlderUpdate: Bool = false) async throws -> ReadingProgressRecord {
        let target = FavoriteContentTarget.mangaThread(threadID: position.chapterThreadID)
        let record = ReadingProgressRecord(
            contentTarget: target,
            threadID: position.chapterThreadID,
            kind: .manga,
            updatedAt: date,
            lastReadAt: date,
            novel: nil,
            manga: MangaReadingProgressRecord(
                chapterThreadID: position.chapterThreadID,
                chapterView: position.chapterView,
                lastChapter: position.chapterTitle,
                mangaPageIndex: position.pageIndex,
                mangaPageCount: position.pageCount
            )
        )
        try await save(record, discardingOlderUpdate: discardingOlderUpdate)
        return record
    }

    @discardableResult
    public func saveMangaTitle(
        cleanBookName: String,
        threadID: String? = nil,
        chapterThreadID: String,
        chapterView: Int = 1,
        chapterTitle: String,
        pageIndex: Int,
        pageCount: Int? = nil,
        mangaID: String? = nil,
        date: Date = .now,
        discardingOlderUpdate: Bool = false
    ) async throws -> ReadingProgressRecord {
        guard let mangaID = Self.trimmedNonEmpty(mangaID) else {
            throw YamiboPersistenceError(context: "Manga reading progress requires a stable directory ID")
        }
        let target = FavoriteContentTarget(mangaID: mangaID, mangaCleanBookName: cleanBookName)
        let chapterTID = Self.trimmedNonEmpty(chapterThreadID)
        guard let chapterTID else {
            throw YamiboPersistenceError(context: "Manga reading progress requires a chapter tid")
        }
        let resolvedThreadID = Self.trimmedNonEmpty(threadID) ?? chapterTID
        let record = ReadingProgressRecord(
            contentTarget: target,
            threadID: resolvedThreadID,
            kind: .manga,
            updatedAt: date,
            lastReadAt: date,
            novel: nil,
            manga: MangaReadingProgressRecord(
                chapterThreadID: chapterTID,
                chapterView: chapterView,
                lastChapter: chapterTitle,
                mangaPageIndex: pageIndex,
                mangaPageCount: pageCount
            )
        )
        let changed = try await database.write { db in
            let target = try Self.canonicalTarget(target, in: db)
            if discardingOlderUpdate {
                if let updatedAt = try Double.fetchOne(db, sql: "SELECT updated_at FROM reading_progress WHERE id = ?", arguments: [target.id]),
                   updatedAt > date.timeIntervalSince1970 { return false }
            }
            try Self.upsert(Self.normalizedRecord(record), in: db)
            return true
        }
        if changed { postChangeNotification() }
        return record
    }

    private func save(_ record: ReadingProgressRecord, discardingOlderUpdate: Bool = false) async throws {
        do {
            let changed = try await database.write { db in
                var record = record
                if let target = record.contentTarget {
                    record.contentTarget = try Self.canonicalTarget(target, in: db)
                }
                if discardingOlderUpdate,
                   let updatedAt = try Double.fetchOne(db, sql: "SELECT updated_at FROM reading_progress WHERE id = ?", arguments: [record.id]),
                   updatedAt > record.updatedAt.timeIntervalSince1970 { return false }
                try Self.upsert(Self.normalizedRecord(record), in: db)
                return true
            }
            if changed { postChangeNotification() }
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    private static func fetchRecord(in db: Database, sql: String, arguments: StatementArguments) throws -> ReadingProgressRecord? {
        guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return nil }
        return try record(from: row)
    }

    private static func fetchAll(in db: Database) throws -> [ReadingProgressRecord] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM reading_progress
            ORDER BY updated_at DESC, id ASC
            """
        ).compactMap(Self.record(from:))
    }

    private static func record(from row: Row) throws -> ReadingProgressRecord? {
        guard let kind = ReadingProgressKind(rawValue: row["kind"] as String),
              let targetKind = FavoriteContentTargetKind(rawValue: row["target_kind"] as String) else {
            YamiboLog.persistence.warning("record(from:) dropped a reading_progress row with unparseable kind/target_kind, id=\(row["id"] as String? ?? "unknown", privacy: .public)")
            return nil
        }
        let target = contentTarget(
            kind: targetKind,
            threadID: row["thread_id"] as String?,
            mangaID: row["manga_id"] as String?,
            cleanBookName: row["clean_book_name"] as String?
        )
        let novel = try novelRecord(from: row)
        let manga = mangaRecord(from: row)
        let thread = threadRecord(from: row)
        return ReadingProgressRecord(
            contentTarget: target,
            threadID: row["thread_id"] as String?,
            kind: kind,
            updatedAt: date(from: row["updated_at"]),
            lastReadAt: optionalDate(from: row["last_read_at"] as Double?),
            novel: novel,
            manga: manga,
            thread: thread
        )
    }

    private static func threadRecord(from row: Row) -> ThreadReadingProgressRecord? {
        guard let lastPage = row["thread_last_page"] as Int? else { return nil }
        return ThreadReadingProgressRecord(
            lastPage: lastPage,
            pageCount: row["thread_page_count"] as Int?,
            anchorPostID: row["thread_anchor_post_id"] as String?
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
            guard let threadID = trimmedNonEmpty(threadID) else { return nil }
            return .normalThread(threadID: threadID)
        case .novelThread:
            guard let threadID = trimmedNonEmpty(threadID) else { return nil }
            return .novelThread(threadID: threadID)
        case .mangaTitle:
            guard let cleanBookName = trimmedNonEmpty(cleanBookName) else { return nil }
            return FavoriteContentTarget(mangaID: mangaID ?? cleanBookName, mangaCleanBookName: cleanBookName)
        case .mangaThread:
            guard let threadID = trimmedNonEmpty(threadID) else { return nil }
            return .mangaThread(threadID: threadID)
        }
    }

    private static func novelRecord(from row: Row) throws -> NovelReadingProgressRecord? {
        guard (row["novel_last_view"] as Int?) != nil else { return nil }
        let resumePoint: NovelResumePoint?
        if let resumeJSON = row["novel_resume_point_json"] as String?,
           let data = resumeJSON.data(using: .utf8) {
            do {
                resumePoint = try JSONDecoder().decode(NovelResumePoint.self, from: data)
            } catch {
                YamiboLog.persistence.warning("novelRecord(from:) failed to decode novel_resume_point_json; degrading to coarse last-view position: \(error)")
                resumePoint = nil
            }
        } else {
            resumePoint = nil
        }
        return NovelReadingProgressRecord(
            lastView: row["novel_last_view"],
            lastChapter: row["novel_last_chapter"] as String?,
            authorID: row["novel_author_id"] as String?,
            novelResumePoint: resumePoint,
            novelMaxView: row["novel_max_view"] as Int?,
            novelDocumentSurfaceProgressPercent: row["novel_document_surface_progress_percent"] as Int?
        )
    }

    private static func mangaRecord(from row: Row) -> MangaReadingProgressRecord? {
        guard let lastChapter = row["manga_last_chapter"] as String?,
              let chapterThreadID = row["manga_chapter_thread_id"] as String?,
              let pageIndex = row["manga_page_index"] as Int? else {
            return nil
        }
        return MangaReadingProgressRecord(
            chapterThreadID: chapterThreadID,
            chapterView: row["manga_chapter_view"] as Int? ?? 1,
            lastChapter: lastChapter,
            mangaPageIndex: pageIndex,
            mangaPageCount: row["manga_page_count"] as Int?
        )
    }

    private static func upsert(_ record: ReadingProgressRecord, in db: Database) throws {
        var record = record
        if let target = record.contentTarget { record.contentTarget = try canonicalTarget(target, in: db) }
        let columns = targetColumns(for: record.contentTarget)
        let novelResumePointJSON: String?
        if let resumePoint = record.novel?.novelResumePoint {
            do {
                let data = try JSONEncoder().encode(resumePoint)
                novelResumePointJSON = String(data: data, encoding: .utf8)
            } catch {
                YamiboLog.persistence.error("upsert(_:in:) failed to encode novel resume point; row will be written without it: \(error)")
                novelResumePointJSON = nil
            }
        } else {
            novelResumePointJSON = nil
        }
        try db.execute(
            sql: """
            INSERT INTO reading_progress
            (
                id, target_kind, thread_id, manga_id, clean_book_name, kind, updated_at, last_read_at,
                novel_last_view, novel_last_chapter, novel_author_id, novel_resume_point_json,
                novel_max_view, novel_document_surface_progress_percent,
                manga_chapter_thread_id, manga_chapter_view, manga_last_chapter, manga_page_index, manga_page_count,
                thread_last_page, thread_page_count, thread_anchor_post_id
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                record.id,
                columns.kind.rawValue,
                columns.threadID ?? record.threadID,
                columns.mangaID,
                columns.cleanBookName,
                record.kind.rawValue,
                timeInterval(from: record.updatedAt),
                record.lastReadAt.map(timeInterval(from:)),
                record.novel?.lastView,
                record.novel?.lastChapter,
                record.novel?.authorID,
                novelResumePointJSON,
                record.novel?.novelMaxView,
                record.novel?.novelDocumentSurfaceProgressPercent,
                record.manga?.chapterThreadID,
                record.manga?.chapterView,
                record.manga?.lastChapter,
                record.manga?.mangaPageIndex,
                record.manga?.mangaPageCount,
                record.thread?.lastPage,
                record.thread?.pageCount,
                record.thread?.anchorPostID,
            ]
        )
    }

    private static func targetColumns(
        for target: FavoriteContentTarget?
    ) -> (kind: FavoriteContentTargetKind, threadID: String?, mangaID: String?, cleanBookName: String?) {
        switch target {
        case let .normalThread(threadID):
            return (.normalThread, threadID, nil, nil)
        case let .novelThread(threadID):
            return (.novelThread, threadID, nil, nil)
        case let .mangaTitle(mangaID, cleanBookName):
            return (.mangaTitle, nil, mangaID, cleanBookName)
        case let .mangaThread(threadID):
            return (.mangaThread, threadID, nil, nil)
        case nil:
            return (.mangaTitle, nil, nil, nil)
        }
    }

    private static func normalizedRecord(_ record: ReadingProgressRecord) -> ReadingProgressRecord {
        let contentTarget: FavoriteContentTarget?
        switch record.kind {
        case .novel:
            if let existing = record.contentTarget {
                contentTarget = existing
            } else if let threadID = trimmedNonEmpty(record.threadID) {
                contentTarget = .novelThread(threadID: threadID)
            } else {
                contentTarget = nil
            }
        case .thread:
            if let existing = record.contentTarget {
                contentTarget = existing
            } else if let threadID = trimmedNonEmpty(record.threadID) {
                contentTarget = .normalThread(threadID: threadID)
            } else {
                contentTarget = nil
            }
        case .manga:
            contentTarget = record.contentTarget ?? fallbackMangaTarget(for: record)
        }
        return ReadingProgressRecord(
            contentTarget: contentTarget,
            threadID: contentTarget?.threadID ?? record.threadID,
            kind: record.kind,
            updatedAt: record.updatedAt,
            lastReadAt: record.lastReadAt,
            novel: record.novel,
            manga: record.manga,
            thread: record.thread
        )
    }

    private static func fallbackMangaTarget(for record: ReadingProgressRecord) -> FavoriteContentTarget? {
        guard record.kind == .manga else { return nil }
        let threadID = trimmedNonEmpty(record.threadID)
            ?? record.manga?.chapterThreadID
        guard let threadID else { return nil }
        let name = trimmedNonEmpty(record.manga?.lastChapter) ?? threadID
        return FavoriteContentTarget(mangaID: "thread:\(threadID)", mangaCleanBookName: name)
    }

    nonisolated func notifyIdentityMigrationCommitted() {
        postChangeNotification()
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }

    private static func timeInterval(from date: Date) -> Double {
        date.timeIntervalSince1970
    }

    private static func date(from value: Double) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private static func optionalDate(from value: Double?) -> Date? {
        value.map(Date.init(timeIntervalSince1970:))
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func canonicalTarget(_ target: FavoriteContentTarget, in db: Database) throws -> FavoriteContentTarget {
        guard case let .mangaTitle(id, title) = target,
              try db.tableExists("manga_identities") else { return target }
        let canonical = try MangaDirectoryIdentityDatabase.canonicalID(MangaDirectoryID(rawValue: id), in: db)
        let name = try String.fetchOne(db, sql: "SELECT name FROM manga_identities WHERE id = ?", arguments: [canonical.rawValue]) ?? title
        return .mangaTitle(mangaID: canonical.rawValue, cleanBookName: name)
    }
}

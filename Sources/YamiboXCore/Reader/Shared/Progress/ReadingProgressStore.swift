import Foundation
@preconcurrency import GRDB

public actor ReadingProgressStore {
    public static let didChangeNotification = Notification.Name("yamibox.readingProgressStore.didChange")
    public static let changeIDUserInfoKey = "changeID"
    nonisolated(unsafe) private static var databasePoolCache: [String: DatabasePool] = [:]
    private static let databasePoolCacheLock = NSLock()

    public nonisolated let changeID = UUID().uuidString

    private let defaults: UserDefaults
    private let key: String
    private let database: DatabasePool

    public init(
        defaults: UserDefaults = .standard,
        key: String = "yamibox.readingProgress.records"
    ) {
        self.defaults = defaults
        self.key = key
        self.database = Self.openDatabase(defaults: defaults, key: key)
    }

    init(
        defaults: UserDefaults = .standard,
        key: String = "yamibox.readingProgress.records",
        databasePool: DatabasePool
    ) {
        self.defaults = defaults
        self.key = key
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
    public func load(threadID: String) async -> ReadingProgressRecord? {
        guard let threadID = Self.trimmedNonEmpty(threadID) else { return nil }
        do {
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
        } catch {
            YamiboLog.persistence.warning("load(threadID:) failed to read reading progress; treating as no recorded progress: \(error)")
            return nil
        }
    }

    public func loadAll() async -> [ReadingProgressRecord] {
        do {
            return try await database.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM reading_progress
                    ORDER BY updated_at DESC, id ASC
                    """
                ).compactMap(Self.record(from:))
            }
        } catch {
            YamiboLog.persistence.warning("loadAll() failed to read reading progress list; returning empty list: \(error)")
            return []
        }
    }

    public func load(for target: FavoriteContentTarget) async -> ReadingProgressRecord? {
        do {
            return try await database.read { db in
                try Self.fetchRecord(
                    in: db,
                    sql: "SELECT * FROM reading_progress WHERE id = ? LIMIT 1",
                    arguments: [target.id]
                )
            }
        } catch {
            YamiboLog.persistence.warning("load(for:) failed to read reading progress; treating as no recorded progress: \(error)")
            return nil
        }
    }

    public func migrateMangaTitleKey(from oldCleanBookName: String, to newCleanBookName: String) async throws {
        var recordsByKey = Dictionary(uniqueKeysWithValues: await loadAll().map { ($0.id, $0) })
        let oldTarget = FavoriteContentTarget(mangaCleanBookName: oldCleanBookName)
        let newTarget = FavoriteContentTarget(mangaCleanBookName: newCleanBookName)
        if var record = recordsByKey.removeValue(forKey: oldTarget.id) {
            record.contentTarget = newTarget
            recordsByKey[newTarget.id] = record
            try await replaceAll(Array(recordsByKey.values))
            return
        }
        guard let existing = recordsByKey.first(where: { _, record in
            record.contentTarget?.mangaCleanBookName == oldCleanBookName
        }) else { return }
        var record = existing.value
        recordsByKey.removeValue(forKey: existing.key)
        let renamedTarget = record.contentTarget?.renamedMangaTitle(to: newCleanBookName) ?? newTarget
        record.contentTarget = renamedTarget
        recordsByKey[renamedTarget.id] = record
        try await replaceAll(Array(recordsByKey.values))
    }

    public func delete(threadID: String) async throws {
        guard let threadID = Self.trimmedNonEmpty(threadID) else { return }
        try await database.write { db in
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
                    let normalized = Self.normalizedRecord(record)
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
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    public func clearAll() async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM reading_progress")
        }
        postChangeNotification()
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
        date: Date = .now
    ) async throws -> ReadingProgressRecord {
        guard let threadID = Self.trimmedNonEmpty(threadID) else {
            throw YamiboError.persistenceFailed("Normal thread reading progress requires a thread tid")
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
        try await save(record)
        return record
    }

    @discardableResult
    public func saveNovel(_ position: NovelReadingPosition, date: Date = .now) async throws -> ReadingProgressRecord {
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
        try await save(record)
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
    /// `ForumMangaDetailViewModel`, `AppContinuityWorkflow`'s mode-on branch)
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
    public func saveManga(_ position: MangaProgressReadingPosition, date: Date = .now) async throws -> ReadingProgressRecord {
        guard position.isSmartModeEnabled else {
            return try await saveMangaThread(position, date: date)
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
            date: date
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
    public func saveMangaThread(_ position: MangaProgressReadingPosition, date: Date = .now) async throws -> ReadingProgressRecord {
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
        try await save(record)
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
        date: Date = .now
    ) async throws -> ReadingProgressRecord {
        let target = FavoriteContentTarget(mangaID: mangaID ?? cleanBookName, mangaCleanBookName: cleanBookName)
        let chapterTID = Self.trimmedNonEmpty(chapterThreadID)
        guard let chapterTID else {
            throw YamiboError.persistenceFailed("Manga reading progress requires a chapter tid")
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
        try await database.write { db in
            for candidateID in Self.mangaProgressRetargetCandidateIDs(
                target: target,
                cleanBookName: cleanBookName,
                chapterTID: chapterTID
            ) {
                try db.execute(sql: "DELETE FROM reading_progress WHERE id = ?", arguments: [candidateID])
            }
            try Self.upsert(Self.normalizedRecord(record), in: db)
        }
        postChangeNotification()
        return record
    }

    private func save(_ record: ReadingProgressRecord) async throws {
        do {
            try await database.write { db in
                try Self.upsert(Self.normalizedRecord(record), in: db)
            }
            postChangeNotification()
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
    }

    private static func openDatabase(defaults: UserDefaults, key: String) -> DatabasePool {
        do {
            if defaults === UserDefaults.standard {
                return try cachedDatabasePool(rootDirectory: YamiboDatabase.defaultRootDirectory())
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
                .appendingPathComponent("yamibo-x-reading-progress", isDirectory: true)
                .appendingPathComponent(databaseID, isDirectory: true)
            return try cachedDatabasePool(rootDirectory: root)
        } catch {
            fatalError("Failed to open ReadingProgressStore database: \(error)")
        }
    }

    private static func cachedDatabasePool(rootDirectory: URL) throws -> DatabasePool {
        let key = rootDirectory.standardizedFileURL.path
        databasePoolCacheLock.lock()
        defer { databasePoolCacheLock.unlock() }
        if let pool = databasePoolCache[key] {
            return pool
        }

        let pool = try YamiboDatabase.openPool(rootDirectory: rootDirectory)
        databasePoolCache[key] = pool
        return pool
    }

    private static func fetchRecord(in db: Database, sql: String, arguments: StatementArguments) throws -> ReadingProgressRecord? {
        guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return nil }
        return try record(from: row)
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

    private nonisolated func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
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

    private static func mangaProgressRetargetCandidateIDs(
        target: FavoriteContentTarget,
        cleanBookName: String,
        chapterTID: String?
    ) -> Set<String> {
        guard target.kind == .mangaTitle else { return [] }
        var candidateIDs = Set<String>()
        candidateIDs.insert(FavoriteContentTarget(mangaCleanBookName: cleanBookName).id)
        if let chapterTID = chapterTID?.trimmingCharacters(in: .whitespacesAndNewlines), !chapterTID.isEmpty {
            candidateIDs.insert(FavoriteContentTarget(mangaID: "chapter:\(chapterTID)", mangaCleanBookName: cleanBookName).id)
            candidateIDs.insert(FavoriteContentTarget(mangaID: "thread:\(chapterTID)", mangaCleanBookName: cleanBookName).id)
        }
        candidateIDs.remove(target.id)
        return candidateIDs
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

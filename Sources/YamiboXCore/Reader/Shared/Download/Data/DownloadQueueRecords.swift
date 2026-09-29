import Foundation
@preconcurrency import GRDB

extension DownloadStore {
    private static let workColumnList = """
    reader_kind, work_id, owner_name, owner_title, tid, chapter_title, retains_inline_images, state, failure_message, current_bytes_per_second, insertion_index, created_at, updated_at
    """

    /// Queue position order. Every reader of `download_works` must agree
    /// on this ordering or "the next work" and the rendered queue would drift
    /// apart.
    private static let workOrderClause = "ORDER BY insertion_index ASC, reader_kind ASC, owner_name ASC, tid ASC"

    func downloadQueueWorks() async throws -> [DownloadQueueWorkProjection] {
        try await ensureQueueRecovered()
        do {
            return try await database.read { db in
                try Self.allRawWorks(in: db).map { try Self.queueWorkProjection(from: $0, in: db) }
            }
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func nextDownloadProcessingWork() async throws -> DownloadProcessingWork? {
        try await ensureQueueRecovered()
        do {
            return try await database.read { db in
                try Self.firstRawWork(in: db).map(Self.processingWork(from:))
            }
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func downloadProcessingWork(id: DownloadWorkID) async throws -> DownloadProcessingWork? {
        try await ensureQueueRecovered()
        do {
            return try await database.read { db in
                try Self.rawWork(workID: id.rawValue, readerKind: id.readerKind, in: db)
                    .map(Self.processingWork(from:))
            }
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func enqueueNovelDownloadWork(_ request: NovelDownloadWorkRequest) async throws -> NovelDownloadEnqueueResult {
        try await enqueueNovelDownloadWork(request, skipsExistingDownloadedEntry: true)
    }

    func enqueueNovelDownloadUpdateWork(_ request: NovelDownloadWorkRequest) async throws -> NovelDownloadEnqueueResult {
        try await enqueueNovelDownloadWork(request, skipsExistingDownloadedEntry: false)
    }

    private func enqueueNovelDownloadWork(
        _ request: NovelDownloadWorkRequest,
        skipsExistingDownloadedEntry: Bool
    ) async throws -> NovelDownloadEnqueueResult {
        try await ensureQueueRecovered()
        do {
            let result: NovelDownloadEnqueueResult = try await database.write { db in
                let normalizedRequest = try Self.normalizedNovelWorkRequest(request)
                let entryID = DownloadEntryID(
                    readerKind: .novel,
                    ownerKey: normalizedRequest.groupKey,
                    entryKey: normalizedRequest.entryKey
                )
                let title = normalizedRequest.title.isEmpty
                    ? L10n.string("reader.page_number_spaced", normalizedRequest.view)
                    : normalizedRequest.title
                if skipsExistingDownloadedEntry,
                   let entry = try Self.novelEntry(entryKey: entryID.entryKey, in: db) {
                    try Self.updateNovelEntryDisplayMetadata(
                        entryKey: entryID.entryKey,
                        ownerTitle: normalizedRequest.ownerTitle,
                        title: title,
                        in: db
                    )
                    return .alreadyDownloaded(
                        try Self.novelEntry(entryKey: entryID.entryKey, in: db) ?? entry
                    )
                }
                if let work = try Self.rawWork(
                    readerKind: .novel,
                    ownerKey: entryID.ownerKey,
                    entryKey: entryID.entryKey,
                    in: db
                ) {
                    let updatedWork = work.updatingDisplay(
                        ownerTitle: normalizedRequest.ownerTitle,
                        title: title
                    )
                    try Self.save(updatedWork, replacing: work, in: db)
                    return .alreadyQueued(try Self.queueWorkProjection(from: updatedWork, in: db))
                }
                return .enqueued(try Self.enqueueNewWork(
                    readerKind: .novel,
                    ownerKey: normalizedRequest.groupKey,
                    ownerTitle: normalizedRequest.ownerTitle,
                    entryKey: normalizedRequest.entryKey,
                    title: title,
                    targetImageURLs: normalizedRequest.targetImageURLs,
                    retainsInlineImages: normalizedRequest.retainsInlineImages,
                    in: db
                ))
            }
            if result.enqueuedWork != nil {
                notifyDownloadDidChange()
            }
            return result
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func retryFailedDownloadWorks() async throws {
        try await ensureQueueRecovered()
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                    UPDATE download_works
                    SET state = ?, failure_message = NULL, current_bytes_per_second = 0, updated_at = ?
                    WHERE state = ?
                    """,
                    arguments: [
                        DownloadWorkState.queued.rawValue,
                        downloadTimeInterval(from: Date()),
                        DownloadWorkState.failed.rawValue
                    ]
                )
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func updateDownloadWorkProgress(
        id: DownloadWorkID,
        targetImageURLs: [URL]?,
        completedImageURLs: [URL],
        currentBytesPerSecond: Int?
    ) async throws {
        try await ensureQueueRecovered()
        try await updateRawWork(id: id) { work in
            work.updatingProgress(
                targetImageURLs: targetImageURLs,
                completedImageURLs: completedImageURLs,
                currentBytesPerSecond: currentBytesPerSecond
            )
        }
    }

    func prepareDownloadWorkForRun(
        id: DownloadWorkID,
        targetImageURLs: [URL]?,
        completedImageURLs: [URL]
    ) async throws {
        try await ensureQueueRecovered()
        try await updateRawWork(id: id) { work in
            work.preparingForRun(targetImageURLs: targetImageURLs, completedImageURLs: completedImageURLs)
        }
    }

    func finishDownloadWork(id: DownloadWorkID) async throws {
        try await ensureQueueRecovered()
        do {
            try await database.write { db in
                guard let work = try Self.rawWork(workID: id.rawValue, readerKind: id.readerKind, in: db) else {
                    return
                }
                try Self.deleteWork(
                    readerKind: work.readerKind.rawValue,
                    ownerName: work.ownerKey,
                    tid: work.entryKey,
                    in: db
                )
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func finishNovelDownloadWork(id: DownloadWorkID) async throws {
        try await finishDownloadWork(id: id)
    }

    func markDownloadWorkFailed(id: DownloadWorkID, message: String?) async throws {
        try await ensureQueueRecovered()
        do {
            try await database.write { db in
                guard let previous = try Self.rawWork(workID: id.rawValue, readerKind: id.readerKind, in: db) else {
                    return
                }
                var work = previous
                work.state = .failed
                work.failureMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
                if work.failureMessage?.isEmpty == true {
                    work.failureMessage = nil
                }
                work.currentBytesPerSecond = 0
                work.updatedAt = Date()
                try Self.save(work, replacing: previous, in: db)
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func cancelDownloadWork(id: DownloadWorkID) async throws {
        try await cancelDownloadWork { db in
            try Self.rawWork(workID: id.rawValue, readerKind: id.readerKind, in: db)
        }
    }

    func cancelDownloadEntry(_ id: DownloadEntryID) async throws {
        try await cancelDownloadWork { db in
            try Self.rawWork(readerKind: id.readerKind, ownerKey: id.ownerKey, entryKey: id.entryKey, in: db)
        }
    }

    /// Lookup and deletion stay in one transaction, including identity canonicalization.
    private func cancelDownloadWork(
        matching findWork: @escaping @Sendable (Database) throws -> DownloadRawWork?
    ) async throws {
        try await ensureQueueRecovered()
        do {
            try await database.write { db in
                guard let canceled = try findWork(db) else {
                    return
                }
                try Self.deleteWork(
                    readerKind: canceled.readerKind.rawValue,
                    ownerName: canceled.ownerKey,
                    tid: canceled.entryKey,
                    in: db
                )
                try Self.removeUnreferencedImages(
                    candidateImageURLs: canceled.targetImageURLs + canceled.completedImageURLs,
                    fileManager: fileManager,
                    imagesDirectory: imagesDirectory,
                    in: db
                )
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func cancelDownloadGroup(_ id: DownloadGroupID) async throws {
        try await cancelDownloadWorks(readerKind: id.readerKind, ownerKey: id.ownerKey)
    }

    private func cancelDownloadWorks(readerKind: DownloadReaderKind, ownerKey: String) async throws {
        try await ensureQueueRecovered()
        guard let ownerKey = ownerKey.nilIfBlank else { return }
        do {
            try await database.write { db in
                let ownerKey = readerKind == .manga ? try Self.canonicalMangaOwnerKey(ownerKey, in: db) : ownerKey
                let canceled = try Self.rawWorks(readerKind: readerKind, ownerKey: ownerKey, in: db)
                try db.execute(
                    sql: "DELETE FROM download_works WHERE reader_kind = ? AND owner_name = ?",
                    arguments: [readerKind.rawValue, ownerKey]
                )
                try Self.removeUnreferencedImages(
                    candidateImageURLs: canceled.flatMap { $0.targetImageURLs + $0.completedImageURLs },
                    fileManager: fileManager,
                    imagesDirectory: imagesDirectory,
                    in: db
                )
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    /// Called after reader-specific checks, inside the caller's write transaction.
    /// The caller publishes invalidation only after that transaction commits.
    static func enqueueNewWork(
        readerKind: DownloadReaderKind,
        ownerKey: String,
        ownerTitle: String,
        entryKey: String,
        title: String,
        targetImageURLs: [URL],
        retainsInlineImages: Bool,
        in db: Database
    ) throws -> DownloadQueueWorkProjection {
        let insertionIndex = try nextQueueInsertionIndex(in: db)
        let now = Date()
        let work = DownloadRawWork(
            readerKind: readerKind,
            workID: UUID().uuidString,
            ownerKey: ownerKey,
            ownerTitle: ownerTitle,
            entryKey: entryKey,
            title: title,
            targetImageURLs: targetImageURLs,
            completedImageURLs: [],
            retainsInlineImages: retainsInlineImages,
            state: .queued,
            failureMessage: nil,
            currentBytesPerSecond: 0,
            insertionIndex: insertionIndex,
            createdAt: now,
            updatedAt: now
        )
        try save(work, in: db)
        return try queueWorkProjection(from: work, in: db)
    }

    /// Upserts the work row and its two image lists. Pass `previous` (the row the
    /// caller just fetched) so unchanged lists are skipped and appended completions
    /// insert only their new rows — progress ticks fire many times per work, and a
    /// plain INSERT OR REPLACE would additionally cascade-delete both image lists
    /// on every tick (REPLACE deletes the conflicting parent row first).
    static func save(_ work: DownloadRawWork, replacing previous: DownloadRawWork? = nil, in db: Database) throws {
        var work = work
        if work.readerKind == .manga {
            work.ownerKey = try canonicalMangaOwnerKey(work.ownerKey, in: db)
            work.ownerTitle = try String.fetchOne(db, sql: "SELECT name FROM manga_identities WHERE id = ?", arguments: [work.ownerKey]) ?? work.ownerTitle
        }
        try db.execute(
            sql: """
            INSERT INTO download_works
            (reader_kind, work_id, owner_name, owner_title, tid, chapter_title, retains_inline_images, state, failure_message, current_bytes_per_second, insertion_index, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(reader_kind, owner_name, tid) DO UPDATE SET
                work_id = excluded.work_id,
                owner_title = excluded.owner_title,
                chapter_title = excluded.chapter_title,
                retains_inline_images = excluded.retains_inline_images,
                state = excluded.state,
                failure_message = excluded.failure_message,
                current_bytes_per_second = excluded.current_bytes_per_second,
                insertion_index = excluded.insertion_index,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
            """,
            arguments: [
                work.readerKind.rawValue,
                work.workID,
                work.ownerKey,
                work.ownerTitle,
                work.entryKey,
                work.title,
                work.retainsInlineImages,
                work.state.rawValue,
                work.failureMessage,
                work.currentBytesPerSecond,
                work.insertionIndex,
                downloadTimeInterval(from: work.createdAt),
                downloadTimeInterval(from: work.updatedAt)
            ]
        )
        try syncImageList(
            table: "download_work_images",
            readerKind: work.readerKind.rawValue,
            ownerName: work.ownerKey,
            tid: work.entryKey,
            from: previous?.targetImageURLs,
            to: work.targetImageURLs,
            in: db
        )
        try syncImageList(
            table: "download_completed_images",
            readerKind: work.readerKind.rawValue,
            ownerName: work.ownerKey,
            tid: work.entryKey,
            from: previous?.completedImageURLs,
            to: work.completedImageURLs,
            in: db
        )
    }

    /// Writes only the difference between the persisted list (`from`) and the new
    /// list (`to`): no-op when equal, suffix-only inserts when appended, and a full
    /// rewrite otherwise (or when the caller has no fetched previous state).
    private static func syncImageList(
        table: String,
        readerKind: String,
        ownerName: String,
        tid: String,
        from previousImageURLs: [URL]?,
        to imageURLs: [URL],
        in db: Database
    ) throws {
        guard let previousImageURLs else {
            try replaceImageList(table: table, readerKind: readerKind, ownerName: ownerName, tid: tid, imageURLs: imageURLs, in: db)
            return
        }
        let previous = previousImageURLs.map(\.absoluteString)
        let updated = imageURLs.map(\.absoluteString)
        if previous == updated { return }
        guard updated.count > previous.count, Array(updated.prefix(previous.count)) == previous else {
            try replaceImageList(table: table, readerKind: readerKind, ownerName: ownerName, tid: tid, imageURLs: imageURLs, in: db)
            return
        }
        for index in previous.count..<updated.count {
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO \(table) (reader_kind, owner_name, tid, manual_order, image_url)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [readerKind, ownerName, tid, index, updated[index]]
            )
        }
    }

    static func rawWork(
        workID: String,
        readerKind: DownloadReaderKind,
        in db: Database
    ) throws -> DownloadRawWork? {
        guard let workID = workID.nilIfBlank,
              let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(workColumnList)
                FROM download_works
                WHERE reader_kind = ? AND work_id = ?
                """,
                arguments: [readerKind.rawValue, workID]
              ) else {
            return nil
        }
        return try rawWork(from: row, in: db)
    }

    static func rawWork(
        readerKind: DownloadReaderKind,
        ownerKey: String,
        entryKey: String,
        in db: Database
    ) throws -> DownloadRawWork? {
        let ownerKey = readerKind == .manga ? try canonicalMangaOwnerKey(ownerKey, in: db) : ownerKey
        guard let ownerKey = ownerKey.nilIfBlank,
              let entryKey = entryKey.nilIfBlank,
              let row = try Row.fetchOne(
                db,
                sql: """
                SELECT \(workColumnList)
                FROM download_works
                WHERE reader_kind = ? AND owner_name = ? AND tid = ?
                """,
                arguments: [readerKind.rawValue, ownerKey, entryKey]
              ) else {
            return nil
        }
        return try rawWork(from: row, in: db)
    }

    static func rawWorks(
        readerKind: DownloadReaderKind,
        ownerKey: String,
        in db: Database
    ) throws -> [DownloadRawWork] {
        let ownerKey = readerKind == .manga ? try canonicalMangaOwnerKey(ownerKey, in: db) : ownerKey
        return try Row.fetchAll(
            db,
            sql: """
            SELECT \(workColumnList)
            FROM download_works
            WHERE reader_kind = ? AND owner_name = ?
            ORDER BY insertion_index ASC, owner_name ASC, tid ASC
            """,
            arguments: [readerKind.rawValue, ownerKey]
        ).compactMap { try rawWork(from: $0, in: db) }
    }

    static func allRawWorks(in db: Database) throws -> [DownloadRawWork] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT \(workColumnList)
            FROM download_works
            \(workOrderClause)
            """
        ).compactMap { try rawWork(from: $0, in: db) }
    }

    /// Head-of-queue lookup for the processing loop. `allRawWorks(in:).first`
    /// paid `rawWork(from:in:)`'s two image-list subqueries for every queued
    /// row just to keep one; here only the first decodable header row is
    /// hydrated. A lazy cursor instead of `LIMIT 1` so that a row with an
    /// unknown `reader_kind` is skipped exactly as `allRawWorks().first`
    /// skipped it.
    static func firstRawWork(in db: Database) throws -> DownloadRawWork? {
        let rows = try Row.fetchCursor(
            db,
            sql: """
            SELECT \(workColumnList)
            FROM download_works
            \(workOrderClause)
            """
        )
        while let row = try rows.next() {
            // Cursor rows are reused buffers; copy so the header values stay
            // stable across the nested image-list queries.
            if let work = try rawWork(from: row.copy(), in: db) {
                return work
            }
        }
        return nil
    }

    static func queueWorkProjection(from work: DownloadRawWork, in db: Database) throws -> DownloadQueueWorkProjection {
        let groupID = DownloadGroupID(readerKind: work.readerKind, ownerKey: work.ownerKey)
        let entryID = DownloadEntryID(readerKind: work.readerKind, ownerKey: work.ownerKey, entryKey: work.entryKey)
        // Paused and failed work may never be saved again after a rename.
        // Resolve its display name even when the rebuildable directory is gone.
        let ownerTitle = work.readerKind == .manga
            ? try mangaOwnerTitle(work.ownerKey, fallback: work.ownerTitle, in: db)
            : work.ownerTitle
        return DownloadQueueWorkProjection(
            id: DownloadWorkID(readerKind: work.readerKind, rawValue: work.workID),
            groupID: groupID,
            entryID: entryID,
            ownerTitle: ownerTitle,
            title: downloadEntryTitle(chapterTitle: work.title, entryKey: work.entryKey),
            progress: DownloadProgress(
                completedUnitCount: work.completedImageURLs.count,
                targetUnitCount: work.targetImageURLs.count
            ),
            state: work.state,
            failureMessage: work.failureMessage,
            currentBytesPerSecond: work.currentBytesPerSecond,
            insertionIndex: work.insertionIndex
        )
    }

    static func processingWork(from work: DownloadRawWork) -> DownloadProcessingWork {
        DownloadProcessingWork(
            id: DownloadWorkID(readerKind: work.readerKind, rawValue: work.workID),
            entryID: DownloadEntryID(readerKind: work.readerKind, ownerKey: work.ownerKey, entryKey: work.entryKey),
            ownerTitle: work.ownerTitle,
            title: downloadEntryTitle(chapterTitle: work.title, entryKey: work.entryKey),
            targetImageURLs: work.targetImageURLs,
            completedImageURLs: work.completedImageURLs,
            retainsInlineImages: work.retainsInlineImages,
            state: work.state,
            failureMessage: work.failureMessage,
            currentBytesPerSecond: work.currentBytesPerSecond,
            insertionIndex: work.insertionIndex,
            createdAt: work.createdAt,
            updatedAt: work.updatedAt
        )
    }

    static func downloadEntryTitle(chapterTitle: String, entryKey: String) -> String {
        chapterTitle.nilIfBlank ?? entryKey
    }

    private func updateRawWork(
        id: DownloadWorkID,
        transform: @Sendable (DownloadRawWork) -> DownloadRawWork
    ) async throws {
        do {
            try await database.write { db in
                guard let work = try Self.rawWork(workID: id.rawValue, readerKind: id.readerKind, in: db) else {
                    return
                }
                try Self.save(transform(work), replacing: work, in: db)
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    private static func rawWork(from row: Row, in db: Database) throws -> DownloadRawWork? {
        guard let readerKind = DownloadReaderKind(rawValue: row["reader_kind"] as String) else {
            return nil
        }
        let ownerKey = row["owner_name"] as String
        let ownerTitle = (row["owner_title"] as String?) ?? ownerKey
        let entryKey = row["tid"] as String
        return DownloadRawWork(
            readerKind: readerKind,
            workID: row["work_id"],
            ownerKey: ownerKey,
            ownerTitle: ownerTitle,
            entryKey: entryKey,
            title: row["chapter_title"],
            targetImageURLs: try imageURLs(
                table: "download_work_images",
                readerKind: readerKind.rawValue,
                ownerName: ownerKey,
                tid: entryKey,
                in: db
            ),
            completedImageURLs: try imageURLs(
                table: "download_completed_images",
                readerKind: readerKind.rawValue,
                ownerName: ownerKey,
                tid: entryKey,
                in: db
            ),
            retainsInlineImages: (row["retains_inline_images"] as Bool?) ?? false,
            state: DownloadWorkState(rawValue: row["state"] as String) ?? .paused,
            failureMessage: row["failure_message"] as String?,
            currentBytesPerSecond: row["current_bytes_per_second"] as Int,
            insertionIndex: row["insertion_index"] as Int,
            createdAt: downloadOptionalDate(from: row["created_at"] as Double?) ?? Date(timeIntervalSince1970: 0),
            updatedAt: downloadOptionalDate(from: row["updated_at"] as Double?) ?? Date(timeIntervalSince1970: 0)
        )
    }
}

struct DownloadRawWork: Sendable {
    var readerKind: DownloadReaderKind
    var workID: String
    var ownerKey: String
    var ownerTitle: String
    var entryKey: String
    var title: String
    var targetImageURLs: [URL]
    var completedImageURLs: [URL]
    var retainsInlineImages: Bool
    var state: DownloadWorkState
    var failureMessage: String?
    var currentBytesPerSecond: Int
    var insertionIndex: Int
    var createdAt: Date
    var updatedAt: Date
}

private extension DownloadRawWork {
    func updatingDisplay(ownerTitle: String, title: String, at date: Date = .now) -> DownloadRawWork {
        DownloadRawWork(
            readerKind: readerKind,
            workID: workID,
            ownerKey: ownerKey,
            ownerTitle: ownerTitle,
            entryKey: entryKey,
            title: title,
            targetImageURLs: targetImageURLs,
            completedImageURLs: completedImageURLs,
            retainsInlineImages: retainsInlineImages,
            state: state,
            failureMessage: failureMessage,
            currentBytesPerSecond: currentBytesPerSecond,
            insertionIndex: insertionIndex,
            createdAt: createdAt,
            updatedAt: date
        )
    }

    func updatingProgress(
        targetImageURLs: [URL]? = nil,
        completedImageURLs: [URL],
        currentBytesPerSecond: Int? = nil,
        at date: Date = .now
    ) -> DownloadRawWork {
        DownloadRawWork(
            readerKind: readerKind,
            workID: workID,
            ownerKey: ownerKey,
            ownerTitle: ownerTitle,
            entryKey: entryKey,
            title: title,
            targetImageURLs: targetImageURLs?.removingDuplicateURLs() ?? self.targetImageURLs,
            completedImageURLs: completedImageURLs.removingDuplicateURLs(),
            retainsInlineImages: retainsInlineImages,
            state: state,
            failureMessage: failureMessage,
            currentBytesPerSecond: currentBytesPerSecond ?? self.currentBytesPerSecond,
            insertionIndex: insertionIndex,
            createdAt: createdAt,
            updatedAt: date
        )
    }

    func preparingForRun(
        targetImageURLs: [URL]? = nil,
        completedImageURLs: [URL],
        at date: Date = .now
    ) -> DownloadRawWork {
        DownloadRawWork(
            readerKind: readerKind,
            workID: workID,
            ownerKey: ownerKey,
            ownerTitle: ownerTitle,
            entryKey: entryKey,
            title: title,
            targetImageURLs: targetImageURLs?.removingDuplicateURLs() ?? self.targetImageURLs,
            completedImageURLs: completedImageURLs.removingDuplicateURLs(),
            retainsInlineImages: retainsInlineImages,
            state: .running,
            failureMessage: nil,
            currentBytesPerSecond: 0,
            insertionIndex: insertionIndex,
            createdAt: createdAt,
            updatedAt: date
        )
    }
}

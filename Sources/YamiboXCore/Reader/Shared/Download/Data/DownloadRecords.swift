import Foundation
@preconcurrency import GRDB

extension DownloadStore {
    private static let novelEntryColumnList = """
    owner_name, owner_title, entry_key, title, thread_id, view, author_id, document_json,
    source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at, updated_at
    """

    func removeDownloadGroup(_ id: DownloadGroupID) async throws {
        switch id.readerKind {
        case .attachment:
            try await removeAttachmentDownloads(ownerKey: id.ownerKey)
        case .manga:
            try await removeMangaDownloadMemberships(forOwnerName: id.ownerKey)
        case .novel:
            try await removeNovelDownloadEntries(ownerName: id.ownerKey)
        }
    }

    func removeDownloadEntry(_ id: DownloadEntryID) async throws {
        switch id.readerKind {
        case .attachment:
            try await removeAttachmentDownloads(ownerKey: id.ownerKey, entryKey: id.entryKey)
        case .manga:
            try await removeMangaDownloadMembership(ownerName: id.ownerKey, tid: id.entryKey)
        case .novel:
            try await removeNovelDownloadEntry(entryKey: id.entryKey)
        }
    }

    func saveNovelDownloadEntry(_ entry: NovelDownloadEntry) async throws {
        let request = NovelDownloadWorkRequest(
            ownerTitle: entry.ownerTitle,
            title: entry.title,
            threadID: entry.document.threadID,
            view: entry.document.view,
            authorID: entry.document.resolvedAuthorID,
            targetImageURLs: entry.imageURLs,
            retainsInlineImages: !entry.imageURLs.isEmpty
        )
        try await saveNovelOfflineSourcePage(
            Self.syntheticSourcePage(from: entry.document),
            request: request,
            updatedAt: entry.updatedAt
        )
    }

    func novelDownloadEntry(id: DownloadEntryID) async -> NovelDownloadEntry? {
        await ensureQueueRecoveredBestEffort()
        guard id.readerKind == .novel else { return nil }
        do {
            return try await database.read { db in
                try Self.novelEntry(entryKey: id.entryKey, in: db)
            }
        } catch {
            YamiboLog.download.error("Failed to read novel offline download entry \(id.entryKey): \(error)")
            return nil
        }
    }

    func allNovelDownloadEntries() async -> [NovelDownloadEntry] {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                try Self.allNovelEntries(in: db)
            }
        } catch {
            YamiboLog.download.error("Failed to read all novel offline download entries: \(error)")
            return []
        }
    }

    func novelDownloadViewsSnapshot(
        ownerTitle: String,
        threadID: String,
        authorID: String?
    ) async -> NovelDownloadViewsSnapshot {
        await ensureQueueRecoveredBestEffort()
        guard let lookup = novelEntryLookup(
            ownerTitle: ownerTitle,
            threadID: threadID,
            view: 1,
            authorID: authorID
        ) else { return NovelDownloadViewsSnapshot() }
        do {
            return try await database.read { db in
                let downloadedRows: [Row]
                if let authorID = lookup.authorID {
                    downloadedRows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT view, source_page_file_name, updated_at
                        FROM download_novel_entries
                        WHERE owner_name = ? AND thread_id = ? AND author_id = ?
                        ORDER BY view ASC
                        """,
                        arguments: [
                            lookup.groupKey,
                            lookup.threadID,
                            authorID
                        ]
                    )
                } else {
                    downloadedRows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT view, source_page_file_name, updated_at
                        FROM download_novel_entries
                        WHERE owner_name = ? AND thread_id = ? AND author_id IS NULL
                        ORDER BY view ASC
                        """,
                        arguments: [
                            lookup.groupKey,
                            lookup.threadID
                        ]
                    )
                }
                var downloadedViews: Set<Int> = []
                var updateTimes: [Int: Date] = [:]
                for row in downloadedRows {
                    let view = row["view"] as Int
                    guard let fileName = row["source_page_file_name"] as String?,
                          Self.payloadFileExists(
                            fileName: fileName,
                            directory: novelSourcePagesDirectory,
                            fileManager: fileManager
                          ) else {
                        continue
                    }
                    downloadedViews.insert(view)
                    if let updatedAt = downloadOptionalDate(from: row["updated_at"] as Double?) {
                        updateTimes[view] = updatedAt
                    }
                }

                let works = try Self.rawWorks(readerKind: .novel, ownerKey: lookup.groupKey, in: db)
                let downloadingViews = Set(works.compactMap { work -> Int? in
                    guard let parsed = NovelDownloadEntry.entryKeyComponents(from: work.entryKey),
                          parsed.threadID == lookup.threadID,
                          parsed.authorID == lookup.authorID else {
                        return nil
                    }
                    return parsed.view
                })
                return NovelDownloadViewsSnapshot(
                    downloadedViews: downloadedViews,
                    downloadingViews: downloadingViews,
                    updateTimesByView: updateTimes
                )
            }
        } catch {
            YamiboLog.download.error("Failed to compute novel offline download views snapshot for thread \(lookup.threadID): \(error)")
            return NovelDownloadViewsSnapshot()
        }
    }

    func removeNovelDownloadViews(
        _ views: Set<Int>,
        ownerTitle: String,
        threadID: String,
        authorID: String?
    ) async throws {
        for view in views {
            guard let lookup = novelEntryLookup(
                ownerTitle: ownerTitle,
                threadID: threadID,
                view: view,
                authorID: authorID
            ) else { continue }
            try await removeNovelDownloadEntry(entryKey: lookup.entryKey)
        }
    }

    private func removeNovelDownloadEntry(entryKey: String) async throws {
        try await ensureQueueRecovered()
        guard let entryKey = entryKey.nilIfBlank else { return }
        do {
            let files = try await database.write { db -> NovelPayloadFileNames in
                let removed = try Self.novelEntry(entryKey: entryKey, in: db)
                let groupKey = removed?.id.ownerKey ?? Self.novelGroupKey(fromEntryKey: entryKey)
                let canceled: DownloadRawWork?
                if let groupKey {
                    do {
                        canceled = try Self.rawWork(readerKind: .novel, ownerKey: groupKey, entryKey: entryKey, in: db)
                    } catch {
                        YamiboLog.download.warning("Failed to look up canceled novel offline download work for entry \(entryKey): \(error)")
                        canceled = nil
                    }
                } else {
                    canceled = nil
                }
                let files = try Self.novelPayloadFileNames(entryKey: entryKey, in: db)
                try Self.deleteNovelEntry(entryKey: entryKey, in: db)
                if let groupKey {
                    try Self.deleteWork(
                        readerKind: DownloadReaderKind.novel.rawValue,
                        ownerName: groupKey,
                        tid: entryKey,
                        in: db
                    )
                }
                try Self.removeUnreferencedImages(
                    candidateImageURLs: (removed?.imageURLs ?? []) + (canceled.map { $0.targetImageURLs + $0.completedImageURLs } ?? []),
                    fileManager: fileManager,
                    imagesDirectory: imagesDirectory,
                    in: db
                )
                return files
            }
            removeNovelPayloadFiles(files)
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    private func removeNovelDownloadEntries(ownerName: String) async throws {
        try await ensureQueueRecovered()
        guard let ownerName = ownerName.nilIfBlank else { return }
        do {
            let files = try await database.write { db -> NovelPayloadFileNames in
                let removed = try Self.novelEntries(ownerName: ownerName, in: db)
                let canceled = try Self.rawWorks(readerKind: .novel, ownerKey: ownerName, in: db)
                let files = try Self.novelPayloadFileNames(ownerName: ownerName, in: db)
                try db.execute(sql: "DELETE FROM download_novel_entries WHERE owner_name = ?", arguments: [ownerName])
                try db.execute(
                    sql: "DELETE FROM download_works WHERE reader_kind = ? AND owner_name = ?",
                    arguments: [DownloadReaderKind.novel.rawValue, ownerName]
                )
                try Self.removeUnreferencedImages(
                    candidateImageURLs: removed.flatMap(\.imageURLs) + canceled.flatMap { $0.targetImageURLs + $0.completedImageURLs },
                    fileManager: fileManager,
                    imagesDirectory: imagesDirectory,
                    in: db
                )
                return files
            }
            removeNovelPayloadFiles(files)
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    static func normalizedNovelWorkRequest(
        _ request: NovelDownloadWorkRequest
    ) throws -> NovelDownloadWorkRequest {
        guard request.entryKey.nilIfBlank != nil else {
            throw YamiboPersistenceError(context: "Novel offline download entry is empty")
        }
        return NovelDownloadWorkRequest(
            ownerTitle: novelDisplayOwnerTitle(ownerTitle: request.ownerTitle, threadID: request.threadID),
            title: request.title,
            threadID: request.threadID,
            view: request.view,
            authorID: request.authorID,
            targetImageURLs: request.targetImageURLs,
            retainsInlineImages: request.retainsInlineImages
        )
    }

    static func novelEntry(entryKey: String, in db: Database) throws -> NovelDownloadEntry? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT \(novelEntryColumnList)
            FROM download_novel_entries
            WHERE entry_key = ?
            """,
            arguments: [entryKey]
        ) else {
            return nil
        }
        return try novelEntry(from: row, in: db)
    }

    static func novelEntries(ownerName: String, in db: Database) throws -> [NovelDownloadEntry] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT \(novelEntryColumnList)
            FROM download_novel_entries
            WHERE owner_name = ?
            ORDER BY owner_name ASC, view ASC, entry_key ASC
            """,
            arguments: [ownerName]
        ).map { try novelEntry(from: $0, in: db) }
    }

    static func allNovelEntries(in db: Database) throws -> [NovelDownloadEntry] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT \(novelEntryColumnList)
            FROM download_novel_entries
            ORDER BY owner_name ASC, view ASC, entry_key ASC
            """
        ).map { try novelEntry(from: $0, in: db) }
    }

    static func novelEntryByteCount(entryKey: String, in db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT byte_count FROM download_novel_entries WHERE entry_key = ?",
            arguments: [entryKey]
        ) ?? 0
    }

    static func saveNovelSourcePageMetadata(
        request: NovelDownloadWorkRequest,
        documentJSON: String,
        sourceFileName: String,
        sourceFingerprint: String,
        sourceByteCount: Int,
        imageURLs: [URL],
        updatedAt: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO download_novel_entries
            (
                owner_name, owner_title, entry_key, title, thread_id, view, author_id, document_json,
                source_page_file_name, source_page_schema_version, source_page_fingerprint,
                byte_count, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM download_novel_entries WHERE entry_key = ?), ?), ?)
            """,
            arguments: [
                request.groupKey,
                request.ownerTitle,
                request.entryKey,
                request.title.isEmpty ? L10n.string("reader.page_number_spaced", request.view) : request.title,
                request.threadID,
                request.view,
                request.authorID,
                documentJSON,
                sourceFileName,
                NovelDownloadEntry.sourcePageSchemaVersion,
                sourceFingerprint,
                sourceByteCount,
                request.entryKey,
                downloadTimeInterval(from: updatedAt),
                downloadTimeInterval(from: updatedAt)
            ]
        )
        try db.execute(
            sql: "DELETE FROM download_novel_entry_images WHERE entry_key = ?",
            arguments: [request.entryKey]
        )
        for (index, imageURL) in imageURLs.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO download_novel_entry_images (entry_key, manual_order, image_url)
                VALUES (?, ?, ?)
                """,
                arguments: [request.entryKey, index, imageURL.absoluteString]
            )
        }
    }

    static func imageURLsForNovelSourcePageMetadata(
        request: NovelDownloadWorkRequest,
        imageURLs: [URL],
        preservesExistingImageReferencesWhenEmpty: Bool,
        in db: Database
    ) throws -> [URL] {
        guard preservesExistingImageReferencesWhenEmpty, imageURLs.isEmpty else {
            return imageURLs
        }
        return try novelImageURLs(entryKey: request.entryKey, in: db)
    }

    static func updateNovelEntryDisplayMetadata(
        entryKey: String,
        ownerTitle: String,
        title: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE download_novel_entries
            SET owner_title = ?, title = ?
            WHERE entry_key = ?
            """,
            arguments: [ownerTitle, title, entryKey]
        )
    }

    private static func novelEntry(from row: Row, in db: Database) throws -> NovelDownloadEntry {
        var projection = try decodeNovelDocument(row["document_json"] as String)
        projection.threadID = row["thread_id"] as String
        projection.view = row["view"] as Int
        projection.resolvedAuthorID = row["author_id"] as String?
        return NovelDownloadEntry(
            ownerTitle: (row["owner_title"] as String?) ?? novelDisplayOwnerTitle(ownerTitle: "", threadID: projection.threadID),
            title: row["title"],
            document: projection,
            imageURLs: try novelImageURLs(entryKey: row["entry_key"], in: db),
            updatedAt: downloadOptionalDate(from: row["updated_at"] as Double?) ?? Date(timeIntervalSince1970: 0)
        )
    }

    static func novelImageURLs(entryKey: String, in db: Database) throws -> [URL] {
        try String.fetchAll(
            db,
            sql: """
            SELECT image_url
            FROM download_novel_entry_images
            WHERE entry_key = ?
            ORDER BY manual_order ASC
            """,
            arguments: [entryKey]
        ).compactMap(URL.init(string:))
    }

    private static func deleteNovelEntry(entryKey: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM download_novel_entries WHERE entry_key = ?",
            arguments: [entryKey]
        )
    }

    static func encodeNovelDocument(_ projection: NovelReaderProjection) throws -> String {
        let data = try JSONEncoder().encode(projection)
        guard let value = String(data: data, encoding: .utf8) else {
            throw YamiboPersistenceError(context: "Failed to encode novel offline download document")
        }
        return value
    }

    private static func decodeNovelDocument(_ value: String) throws -> NovelReaderProjection {
        guard let data = value.data(using: .utf8) else {
            throw YamiboPersistenceError(context: "Failed to decode novel offline download document")
        }
        return try JSONDecoder().decode(NovelReaderProjection.self, from: data)
    }

    static func novelDisplayOwnerTitle(ownerTitle: String, threadID: String) -> String {
        ownerTitle.nilIfBlank ?? threadID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func novelGroupKey(fromEntryKey entryKey: String) -> String? {
        let components = entryKey.components(separatedBy: "_")
        guard components.count == 6,
              components[0] == "tid",
              components[2] == "author",
              components[4] == "view" else {
            return nil
        }
        return components.prefix(4).joined(separator: "_")
    }

}

import Foundation
@preconcurrency import GRDB

extension OfflineCacheStore {
    private static let novelEntryColumnList = """
    owner_name, owner_title, entry_key, title, thread_id, view, author_id, document_json,
    source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at, updated_at
    """

    func removeOfflineCacheGroup(_ id: OfflineCacheGroupID) async throws {
        switch id.readerKind {
        case .manga:
            try await removeMangaOfflineCacheMemberships(forOwnerName: id.ownerKey)
        case .novel:
            try await removeNovelOfflineCacheEntries(ownerName: id.ownerKey)
        }
    }

    func removeOfflineCacheEntry(_ id: OfflineCacheEntryID) async throws {
        switch id.readerKind {
        case .manga:
            try await removeMangaOfflineCacheMembership(ownerName: id.ownerKey, tid: id.entryKey)
        case .novel:
            try await removeNovelOfflineCacheEntry(entryKey: id.entryKey)
        }
    }

    func saveNovelOfflineCacheEntry(_ entry: NovelOfflineCacheEntry) async throws {
        let request = NovelOfflineCacheWorkRequest(
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

    func novelOfflineCacheEntry(id: OfflineCacheEntryID) async -> NovelOfflineCacheEntry? {
        await ensureQueueRecoveredBestEffort()
        guard id.readerKind == .novel else { return nil }
        do {
            return try await database.read { db in
                try Self.novelEntry(entryKey: id.entryKey, in: db)
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to read novel offline cache entry \(id.entryKey): \(error)")
            return nil
        }
    }

    func allNovelOfflineCacheEntries() async -> [NovelOfflineCacheEntry] {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                try Self.allNovelEntries(in: db)
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to read all novel offline cache entries: \(error)")
            return []
        }
    }

    func novelOfflineCacheViewsSnapshot(
        ownerTitle: String,
        threadID: String,
        authorID: String?
    ) async -> NovelOfflineCacheViewsSnapshot {
        await ensureQueueRecoveredBestEffort()
        guard let lookup = novelEntryLookup(
            ownerTitle: ownerTitle,
            threadID: threadID,
            view: 1,
            authorID: authorID
        ) else { return NovelOfflineCacheViewsSnapshot() }
        do {
            return try await database.read { db in
                let cachedRows: [Row]
                if let authorID = lookup.authorID {
                    cachedRows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT view, source_page_file_name, updated_at
                        FROM offline_cache_novel_entries
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
                    cachedRows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT view, source_page_file_name, updated_at
                        FROM offline_cache_novel_entries
                        WHERE owner_name = ? AND thread_id = ? AND author_id IS NULL
                        ORDER BY view ASC
                        """,
                        arguments: [
                            lookup.groupKey,
                            lookup.threadID
                        ]
                    )
                }
                var cachedViews: Set<Int> = []
                var updateTimes: [Int: Date] = [:]
                for row in cachedRows {
                    let view = row["view"] as Int
                    guard let fileName = row["source_page_file_name"] as String?,
                          Self.payloadFileExists(
                            fileName: fileName,
                            directory: novelSourcePagesDirectory,
                            fileManager: fileManager
                          ) else {
                        continue
                    }
                    cachedViews.insert(view)
                    if let updatedAt = offlineCacheOptionalDate(from: row["updated_at"] as Double?) {
                        updateTimes[view] = updatedAt
                    }
                }

                let works = try Self.rawWorks(readerKind: .novel, ownerKey: lookup.groupKey, in: db)
                let cachingViews = Set(works.compactMap { work -> Int? in
                    guard let parsed = NovelOfflineCacheEntry.entryKeyComponents(from: work.entryKey),
                          parsed.threadID == lookup.threadID,
                          parsed.authorID == lookup.authorID else {
                        return nil
                    }
                    return parsed.view
                })
                return NovelOfflineCacheViewsSnapshot(
                    cachedViews: cachedViews,
                    cachingViews: cachingViews,
                    updateTimesByView: updateTimes
                )
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to compute novel offline cache views snapshot for thread \(lookup.threadID): \(error)")
            return NovelOfflineCacheViewsSnapshot()
        }
    }

    func removeNovelOfflineCacheViews(
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
            try await removeNovelOfflineCacheEntry(entryKey: lookup.entryKey)
        }
    }

    private func removeNovelOfflineCacheEntry(entryKey: String) async throws {
        try await ensureQueueRecovered()
        guard let entryKey = entryKey.mangaReaderTrimmedNonEmpty else { return }
        do {
            let files = try await database.write { db -> NovelPayloadFileNames in
                let removed = try Self.novelEntry(entryKey: entryKey, in: db)
                let groupKey = removed?.id.ownerKey ?? Self.novelGroupKey(fromEntryKey: entryKey)
                let canceled: OfflineCacheRawWork?
                if let groupKey {
                    do {
                        canceled = try Self.rawWork(readerKind: .novel, ownerKey: groupKey, entryKey: entryKey, in: db)
                    } catch {
                        YamiboLog.offlineCache.warning("Failed to look up canceled novel offline cache work for entry \(entryKey): \(error)")
                        canceled = nil
                    }
                } else {
                    canceled = nil
                }
                let files = try Self.novelPayloadFileNames(entryKey: entryKey, in: db)
                try Self.deleteNovelEntry(entryKey: entryKey, in: db)
                if let groupKey {
                    try Self.deleteWork(
                        readerKind: OfflineCacheReaderKind.novel.rawValue,
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
            notifyOfflineCacheDidChange()
        } catch {
            throw offlineCachePersistenceError(from: error)
        }
    }

    private func removeNovelOfflineCacheEntries(ownerName: String) async throws {
        try await ensureQueueRecovered()
        guard let ownerName = ownerName.mangaReaderTrimmedNonEmpty else { return }
        do {
            let files = try await database.write { db -> NovelPayloadFileNames in
                let removed = try Self.novelEntries(ownerName: ownerName, in: db)
                let canceled = try Self.rawWorks(readerKind: .novel, ownerKey: ownerName, in: db)
                let files = try Self.novelPayloadFileNames(ownerName: ownerName, in: db)
                try db.execute(sql: "DELETE FROM offline_cache_novel_entries WHERE owner_name = ?", arguments: [ownerName])
                try db.execute(
                    sql: "DELETE FROM offline_cache_works WHERE reader_kind = ? AND owner_name = ?",
                    arguments: [OfflineCacheReaderKind.novel.rawValue, ownerName]
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
            notifyOfflineCacheDidChange()
        } catch {
            throw offlineCachePersistenceError(from: error)
        }
    }

    static func normalizedNovelWorkRequest(
        _ request: NovelOfflineCacheWorkRequest
    ) throws -> NovelOfflineCacheWorkRequest {
        guard request.entryKey.mangaReaderTrimmedNonEmpty != nil else {
            throw YamiboPersistenceError(context: "Novel offline cache entry is empty")
        }
        return NovelOfflineCacheWorkRequest(
            ownerTitle: novelDisplayOwnerTitle(ownerTitle: request.ownerTitle, threadID: request.threadID),
            title: request.title,
            threadID: request.threadID,
            view: request.view,
            authorID: request.authorID,
            targetImageURLs: request.targetImageURLs,
            retainsInlineImages: request.retainsInlineImages
        )
    }

    static func novelEntry(entryKey: String, in db: Database) throws -> NovelOfflineCacheEntry? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT \(novelEntryColumnList)
            FROM offline_cache_novel_entries
            WHERE entry_key = ?
            """,
            arguments: [entryKey]
        ) else {
            return nil
        }
        return try novelEntry(from: row, in: db)
    }

    static func novelEntries(ownerName: String, in db: Database) throws -> [NovelOfflineCacheEntry] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT \(novelEntryColumnList)
            FROM offline_cache_novel_entries
            WHERE owner_name = ?
            ORDER BY owner_name ASC, view ASC, entry_key ASC
            """,
            arguments: [ownerName]
        ).map { try novelEntry(from: $0, in: db) }
    }

    static func allNovelEntries(in db: Database) throws -> [NovelOfflineCacheEntry] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT \(novelEntryColumnList)
            FROM offline_cache_novel_entries
            ORDER BY owner_name ASC, view ASC, entry_key ASC
            """
        ).map { try novelEntry(from: $0, in: db) }
    }

    static func novelEntryByteCount(entryKey: String, in db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT byte_count FROM offline_cache_novel_entries WHERE entry_key = ?",
            arguments: [entryKey]
        ) ?? 0
    }

    static func saveNovelSourcePageMetadata(
        request: NovelOfflineCacheWorkRequest,
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
            INSERT OR REPLACE INTO offline_cache_novel_entries
            (
                owner_name, owner_title, entry_key, title, thread_id, view, author_id, document_json,
                source_page_file_name, source_page_schema_version, source_page_fingerprint,
                byte_count, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM offline_cache_novel_entries WHERE entry_key = ?), ?), ?)
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
                NovelOfflineCacheEntry.sourcePageSchemaVersion,
                sourceFingerprint,
                sourceByteCount,
                request.entryKey,
                offlineCacheTimeInterval(from: updatedAt),
                offlineCacheTimeInterval(from: updatedAt)
            ]
        )
        try db.execute(
            sql: "DELETE FROM offline_cache_novel_entry_images WHERE entry_key = ?",
            arguments: [request.entryKey]
        )
        for (index, imageURL) in imageURLs.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO offline_cache_novel_entry_images (entry_key, manual_order, image_url)
                VALUES (?, ?, ?)
                """,
                arguments: [request.entryKey, index, imageURL.absoluteString]
            )
        }
    }

    static func imageURLsForNovelSourcePageMetadata(
        request: NovelOfflineCacheWorkRequest,
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
            UPDATE offline_cache_novel_entries
            SET owner_title = ?, title = ?
            WHERE entry_key = ?
            """,
            arguments: [ownerTitle, title, entryKey]
        )
    }

    private static func novelEntry(from row: Row, in db: Database) throws -> NovelOfflineCacheEntry {
        var projection = try decodeNovelDocument(row["document_json"] as String)
        projection.threadID = row["thread_id"] as String
        projection.view = row["view"] as Int
        projection.resolvedAuthorID = row["author_id"] as String?
        return NovelOfflineCacheEntry(
            ownerTitle: (row["owner_title"] as String?) ?? novelDisplayOwnerTitle(ownerTitle: "", threadID: projection.threadID),
            title: row["title"],
            document: projection,
            imageURLs: try novelImageURLs(entryKey: row["entry_key"], in: db),
            updatedAt: offlineCacheOptionalDate(from: row["updated_at"] as Double?) ?? Date(timeIntervalSince1970: 0)
        )
    }

    static func novelImageURLs(entryKey: String, in db: Database) throws -> [URL] {
        try String.fetchAll(
            db,
            sql: """
            SELECT image_url
            FROM offline_cache_novel_entry_images
            WHERE entry_key = ?
            ORDER BY manual_order ASC
            """,
            arguments: [entryKey]
        ).compactMap(URL.init(string:))
    }

    private static func deleteNovelEntry(entryKey: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM offline_cache_novel_entries WHERE entry_key = ?",
            arguments: [entryKey]
        )
    }

    static func encodeNovelDocument(_ projection: NovelReaderProjection) throws -> String {
        let data = try JSONEncoder().encode(projection)
        guard let value = String(data: data, encoding: .utf8) else {
            throw YamiboPersistenceError(context: "Failed to encode novel offline cache document")
        }
        return value
    }

    private static func decodeNovelDocument(_ value: String) throws -> NovelReaderProjection {
        guard let data = value.data(using: .utf8) else {
            throw YamiboPersistenceError(context: "Failed to decode novel offline cache document")
        }
        return try JSONDecoder().decode(NovelReaderProjection.self, from: data)
    }

    static func novelDisplayOwnerTitle(ownerTitle: String, threadID: String) -> String {
        ownerTitle.mangaReaderTrimmedNonEmpty ?? threadID.trimmingCharacters(in: .whitespacesAndNewlines)
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

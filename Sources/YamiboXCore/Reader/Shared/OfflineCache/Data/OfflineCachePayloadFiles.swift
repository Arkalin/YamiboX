import Foundation
@preconcurrency import GRDB

extension OfflineCacheStore {
    func saveNovelOfflineSourcePage(
        _ sourcePage: ForumThreadPage,
        request: NovelOfflineCacheWorkRequest,
        updatedAt: Date = .now,
        completesMatchingWork: Bool = true,
        preservesExistingImageReferencesWhenEmpty: Bool = false
    ) async throws {
        try await recoverQueueStateAfterRestart()
        do {
            let normalized = try Self.normalizedNovelWorkRequest(request)
            let sourceData = try Self.encodeJSONData(sourcePage, context: "novel offline source page")
            let sourceFingerprint = try novelSourcePageFingerprint(for: sourcePage)
            let sourceFileName = novelPayloadFileName(
                prefix: "source",
                entryKey: normalized.entryKey
            )
            let sourceURL = novelSourcePagesDirectory.appendingPathComponent(sourceFileName, isDirectory: false)
            let requestedTitle = normalized.title.isEmpty
                ? L10n.string("reader.page_number_spaced", normalized.view)
                : normalized.title

            // Auto-refresh replays this on every online page load for views that are already
            // offline-cached, so resolve whether anything would actually change before paying
            // for a full re-encode + atomic file rewrite + metadata upsert.
            let sourceUnchanged = try await database.read { db -> Bool in
                let resolvedImageURLs = try Self.imageURLsForNovelSourcePageMetadata(
                    request: normalized,
                    imageURLs: normalized.targetImageURLs,
                    preservesExistingImageReferencesWhenEmpty: preservesExistingImageReferencesWhenEmpty,
                    in: db
                )
                return try Self.novelSourcePageUnchanged(
                    entryKey: normalized.entryKey,
                    ownerTitle: normalized.ownerTitle,
                    title: requestedTitle,
                    sourceFingerprint: sourceFingerprint,
                    resolvedImageURLs: resolvedImageURLs,
                    fileManager: fileManager,
                    novelSourcePagesDirectory: novelSourcePagesDirectory,
                    in: db
                )
            }

            guard !sourceUnchanged else {
                var deletedMatchingWork = false
                if completesMatchingWork {
                    deletedMatchingWork = try await database.write { db -> Bool in
                        try Self.deleteWork(
                            readerKind: OfflineCacheReaderKind.novel.rawValue,
                            ownerName: normalized.groupKey,
                            tid: normalized.entryKey,
                            in: db
                        )
                        return db.changesCount > 0
                    }
                }
                if deletedMatchingWork {
                    notifyOfflineCacheDidChange()
                }
                return
            }

            try ensureNovelSourcePagesDirectoryExists()
            try sourceData.write(to: sourceURL, options: [.atomic])
            let document = try Self.projectionDocument(
                from: sourcePage,
                request: normalized
            )
            let documentJSON = try Self.encodeNovelDocument(document)

            let previousFiles = try await database.write { db in
                // Resolved inside the write transaction: the actor can interleave other work
                // at the awaits above, so a list captured during the earlier read could merge
                // against stale state and overwrite image references written concurrently.
                let resolvedImageURLs = try Self.imageURLsForNovelSourcePageMetadata(
                    request: normalized,
                    imageURLs: normalized.targetImageURLs,
                    preservesExistingImageReferencesWhenEmpty: preservesExistingImageReferencesWhenEmpty,
                    in: db
                )
                let previousFiles = try Self.novelPayloadFileNames(entryKey: normalized.entryKey, in: db)
                try Self.saveNovelSourcePageMetadata(
                    request: normalized,
                    documentJSON: documentJSON,
                    sourceFileName: sourceFileName,
                    sourceFingerprint: sourceFingerprint,
                    sourceByteCount: sourceData.count,
                    imageURLs: resolvedImageURLs,
                    updatedAt: updatedAt,
                    in: db
                )
                if completesMatchingWork {
                    try Self.deleteWork(
                        readerKind: OfflineCacheReaderKind.novel.rawValue,
                        ownerName: normalized.groupKey,
                        tid: normalized.entryKey,
                        in: db
                    )
                }
                return previousFiles
            }
            removeNovelPayloadFiles(NovelPayloadFileNames(
                sourcePageFileNames: previousFiles.sourcePageFileNames.subtracting([sourceFileName])
            ))
            notifyOfflineCacheDidChange()
        } catch {
            throw novelPayloadPersistenceError(from: error)
        }
    }

    /// Fingerprint used by the auto-refresh skip check, computed over a copy with
    /// per-fetch/per-session fields stripped: the Discuz view counter increments on every
    /// visit (including the fetch itself), reply counters bump on activity anywhere in the
    /// thread, and the form hash plus manage-action links rotate with the session. Hashing
    /// the full page would make the skip branch unreachable; the payload file still stores
    /// the complete page.
    func novelSourcePageFingerprint(for sourcePage: ForumThreadPage) throws -> String {
        var canonical = sourcePage
        canonical.totalViews = nil
        canonical.totalReplies = nil
        canonical.formHash = nil
        canonical.posts = canonical.posts.map { post in
            var post = post
            post.manageActions = []
            return post
        }
        let data = try Self.encodeJSONData(canonical, context: "novel offline source page fingerprint")
        return sha256Hex(String(decoding: data, as: UTF8.self))
    }

    private static func novelSourcePageUnchanged(
        entryKey: String,
        ownerTitle: String,
        title: String,
        sourceFingerprint: String,
        resolvedImageURLs: [URL],
        fileManager: FileManager,
        novelSourcePagesDirectory: URL,
        in db: Database
    ) throws -> Bool {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT owner_title, title, source_page_file_name, source_page_fingerprint
            FROM offline_cache_novel_entries
            WHERE entry_key = ?
            """,
            arguments: [entryKey]
        ),
              (row["owner_title"] as String?) == ownerTitle,
              (row["title"] as String?) == title,
              let fileName = (row["source_page_file_name"] as String?)?.mangaReaderTrimmedNonEmpty,
              (row["source_page_fingerprint"] as String?) == sourceFingerprint,
              payloadFileExists(fileName: fileName, directory: novelSourcePagesDirectory, fileManager: fileManager) else {
            return false
        }
        let existingImageURLs = try Self.novelImageURLs(entryKey: entryKey, in: db)
        return existingImageURLs == resolvedImageURLs
    }

    func novelOfflineSourcePage(
        ownerTitle: String,
        threadID: String,
        view: Int,
        authorID: String?
    ) async -> ForumThreadPage? {
        try? await recoverQueueStateAfterRestart()
        guard let identity = novelEntryLookup(
            ownerTitle: ownerTitle,
            threadID: threadID,
            view: view,
            authorID: authorID
        ) else { return nil }
        let fileName: String?
        do {
            fileName = try await database.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                    SELECT source_page_file_name
                    FROM offline_cache_novel_entries
                    WHERE entry_key = ?
                    """,
                    arguments: [identity.entryKey]
                )
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to look up cached novel source page file name for entry \(identity.entryKey): \(error)")
            return nil
        }
        guard let fileName else {
            return nil
        }
        return Self.decodeFile(
            fileName: fileName,
            directory: novelSourcePagesDirectory,
            fileManager: fileManager,
            as: ForumThreadPage.self
        )
    }

    func novelOfflineSourcePageSnapshot(
        threadID: String,
        view: Int,
        authorID: String?
    ) async -> NovelOfflineSourcePageSnapshot? {
        try? await recoverQueueStateAfterRestart()
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return nil }
        let normalizedAuthorID = authorID?.mangaReaderTrimmedNonEmpty
        let entryKey = NovelOfflineCacheEntry.entryKey(
            threadID: normalizedThreadID,
            view: view,
            authorID: normalizedAuthorID
        )
        let row: NovelOfflineSourcePageSnapshotRow?
        do {
            row = try await database.read { db -> NovelOfflineSourcePageSnapshotRow? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT owner_title, source_page_file_name, updated_at
                    FROM offline_cache_novel_entries
                    WHERE entry_key = ? AND source_page_file_name IS NOT NULL
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                    arguments: [entryKey]
                ),
                    let fileName = row["source_page_file_name"] as String? else {
                    return nil
                }
                return NovelOfflineSourcePageSnapshotRow(
                    ownerTitle: (row["owner_title"] as String?)
                        ?? Self.novelDisplayOwnerTitle(ownerTitle: "", threadID: normalizedThreadID),
                    fileName: fileName,
                    updatedAt: novelPayloadOptionalDate(from: row["updated_at"] as Double?)
                )
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to fetch novel offline source page snapshot for entry \(entryKey): \(error)")
            return nil
        }
        guard let row,
              let sourcePage = Self.decodeFile(
                fileName: row.fileName,
                directory: novelSourcePagesDirectory,
                fileManager: fileManager,
                as: ForumThreadPage.self
              ) else {
            return nil
        }
        return NovelOfflineSourcePageSnapshot(
            ownerTitle: row.ownerTitle,
            sourcePage: sourcePage,
            updatedAt: row.updatedAt
        )
    }

    func novelEntryLookup(
        ownerTitle: String,
        threadID: String,
        view: Int,
        authorID: String?
    ) -> NovelEntryLookup? {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else { return nil }
        let identity = NovelReaderCacheIdentity(
            threadID: normalizedThreadID,
            view: max(1, view),
            authorID: authorID
        )
        let normalizedAuthorID = authorID?.mangaReaderTrimmedNonEmpty
        return NovelEntryLookup(
            ownerTitle: Self.novelDisplayOwnerTitle(ownerTitle: ownerTitle, threadID: normalizedThreadID),
            groupKey: NovelOfflineCacheEntry.groupKey(
                threadID: normalizedThreadID,
                authorID: normalizedAuthorID
            ),
            threadID: identity.threadID,
            entryKey: NovelOfflineCacheEntry.entryKey(
                threadID: normalizedThreadID,
                view: view,
                authorID: normalizedAuthorID
            ),
            authorID: normalizedAuthorID
        )
    }

    func novelPayloadFileName(prefix: String, entryKey: String) -> String {
        "\(prefix)_\(sha256Hex(entryKey)).json"
    }

    func removeNovelPayloadFiles(_ files: NovelPayloadFileNames) {
        for fileName in files.sourcePageFileNames {
            do {
                try fileManager.removeItem(at: novelSourcePagesDirectory.appendingPathComponent(fileName, isDirectory: false))
            } catch {
                YamiboLog.offlineCache.error("Failed to remove novel offline payload file \(fileName): \(error)")
            }
        }
    }

    static func novelPayloadFileNames(entryKey: String, in db: Database) throws -> NovelPayloadFileNames {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT source_page_file_name
            FROM offline_cache_novel_entries
            WHERE entry_key = ?
            """,
            arguments: [entryKey]
        ) else {
            return NovelPayloadFileNames()
        }
        return NovelPayloadFileNames(
            sourcePageFileNames: Set((row["source_page_file_name"] as String?).map { [$0] } ?? [])
        )
    }

    static func novelPayloadFileNames(ownerName: String, in db: Database) throws -> NovelPayloadFileNames {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT source_page_file_name
            FROM offline_cache_novel_entries
            WHERE owner_name = ?
            """,
            arguments: [ownerName]
        )
        return NovelPayloadFileNames(
            sourcePageFileNames: Set(rows.compactMap { $0["source_page_file_name"] as String? })
        )
    }

    private static func encodeJSONData<T: Encodable>(_ value: T, context: String) throws -> Data {
        do {
            // Sorted keys make the fingerprint reproducible: re-encoding an unchanged
            // ForumThreadPage must hash identically to the previously stored fingerprint, and
            // JSONEncoder's default key order is not guaranteed stable across separate encode calls.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        } catch {
            throw YamiboError.persistenceFailed("Failed to encode \(context)")
        }
    }

    private static func decodeFile<T: Decodable>(
        fileName: String,
        directory: URL,
        fileManager: FileManager,
        as _: T.Type
    ) -> T? {
        guard payloadFileExists(fileName: fileName, directory: directory, fileManager: fileManager) else {
            return nil
        }
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            YamiboLog.offlineCache.error("Failed to read cached novel payload file \(fileName)")
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            YamiboLog.offlineCache.error("Failed to decode cached novel payload file \(fileName)")
            return nil
        }
        return decoded
    }

    static func payloadFileExists(
        fileName: String,
        directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let value = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let url = directory.appendingPathComponent(value, isDirectory: false)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func projectionDocument(
        from sourcePage: ForumThreadPage,
        request: NovelOfflineCacheWorkRequest
    ) throws -> NovelReaderProjection {
        let authorID = request.authorID
            ?? sourcePage.posts.first?.author.uid?.mangaReaderTrimmedNonEmpty
            ?? "offline"
        return try NovelReaderProjectionBuilder.build(
            from: sourcePage,
            request: NovelPageRequest(
                threadID: request.threadID,
                view: request.view,
                authorID: authorID
            ),
            authorID: authorID,
            projectionSourceFingerprint: "",
            projectionSchemaVersion: 0
        )
    }

    static func syntheticSourcePage(from document: NovelReaderProjection) -> ForumThreadPage {
        let thread = ThreadIdentity(tid: document.threadID)
        let authorID = document.resolvedAuthorID?.mangaReaderTrimmedNonEmpty ?? "offline"
        let posts = document.segments.enumerated().map { index, segment in
            ForumThreadPost(
                postID: document.segmentSources.indices.contains(index)
                    ? document.segmentSources[index]?.ownerPostID ?? "\(document.view)-\(index)"
                    : "\(document.view)-\(index)",
                author: BlogReaderUser(uid: authorID, name: "楼主"),
                contentHTML: syntheticHTML(for: segment, index: index),
                contentText: ""
            )
        }
        return ForumThreadPage(
            thread: thread,
            title: document.threadID,
            posts: posts,
            pageNavigation: ForumPageNavigation(currentPage: document.view, totalPages: document.maxView)
        )
    }

    private static func syntheticHTML(for segment: NovelReaderSegment, index: Int) -> String {
        switch segment {
        case let .text(text, chapterTitle):
            return "<strong>\((chapterTitle ?? "第\(index + 1)章").novelOfflineEscapedHTML)</strong><br>\(text.novelOfflineEscapedHTML)"
        case let .image(url, _):
            return #"<img src="\#(url.absoluteString.novelOfflineEscapedHTML)" />"#
        }
    }

}

struct NovelEntryLookup {
    var ownerTitle: String
    var groupKey: String
    var threadID: String
    var entryKey: String
    var authorID: String?
}

struct NovelPayloadFileNames {
    var sourcePageFileNames: Set<String> = []
}

private struct NovelOfflineSourcePageSnapshotRow: Sendable {
    var ownerTitle: String
    var fileName: String
    var updatedAt: Date?
}

private extension String {
    var novelOfflineEscapedHTML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private func novelPayloadPersistenceError(from error: Error) -> YamiboError {
    if let error = error as? YamiboError {
        return error
    }
    return YamiboError.persistenceFailed(error.localizedDescription)
}

private func novelPayloadOptionalDate(from value: Double?) -> Date? {
    value.map(Date.init(timeIntervalSince1970:))
}

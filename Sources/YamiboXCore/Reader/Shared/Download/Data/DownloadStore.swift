import CryptoKit
import Foundation
@preconcurrency import GRDB

private struct MangaOwnerStateCache: Sendable {
    var signature: [String]
    var imageStamp: Date?
    var sourceStamp: Date?
    var states: [String: MangaDownloadState]
}

final class MangaMissingImageCacheEntry: Sendable {
    let manualOrder: Int
    let imageURL: String

    init(manualOrder: Int, imageURL: String) {
        self.manualOrder = manualOrder
        self.imageURL = imageURL
    }
}

actor DownloadStore {
    let database: DatabasePool
    nonisolated(unsafe) let fileManager: FileManager
    private let baseDirectory: URL
    let imagesDirectory: URL
    let attachmentsDirectory: URL
    let mangaSourcePagesDirectory: URL
    let novelSourcePagesDirectory: URL
    private let updateNotifier = StoreInvalidationBroadcaster<Void>()
    private var didRecoverQueueState = false
    private var queueRecoveryTask: Task<Void, Error>?
    private var mangaOwnerStateCache: [String: MangaOwnerStateCache] = [:]
    private static let mangaReaderKind = "manga"
    nonisolated(unsafe) let sourcePageCache: NSCache<NSString, SourcePageCacheEntry> = {
        let cache = NSCache<NSString, SourcePageCacheEntry>()
        cache.countLimit = 128
        return cache
    }()
    // A missing asset is only a hint: the writer validates its current
    // chapter reference and absence before skipping a completeness check.
    nonisolated(unsafe) let missingMangaImageCache: NSCache<NSString, MangaMissingImageCacheEntry> = {
        let cache = NSCache<NSString, MangaMissingImageCacheEntry>()
        cache.countLimit = 32
        return cache
    }()

    init(
        databasePool: DatabasePool? = nil,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.database = databasePool ?? YamiboDatabasePoolResolver.openDefaultPool(storeName: "DownloadStore")
        self.fileManager = fileManager
        let root = baseDirectory ?? Self.defaultBaseDirectory(fileManager: fileManager)
        self.baseDirectory = root
        self.imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        self.attachmentsDirectory = root.appendingPathComponent("attachments", isDirectory: true)
        self.mangaSourcePagesDirectory = root.appendingPathComponent("manga-source-pages", isDirectory: true)
        self.novelSourcePagesDirectory = root.appendingPathComponent("novel-source-pages", isDirectory: true)
    }

    nonisolated public func downloadUpdates() -> AsyncStream<Void> {
        updateNotifier.stream()
    }

    func mangaDownloadMembership(ownerName: String, tid: String) async -> MangaDownloadMembership? {
        await ensureQueueRecoveredBestEffort()
        guard let id = normalizedID(ownerName: ownerName, tid: tid) else { return nil }
        do {
            return try await database.read { db in
                try Self.membership(
                    ownerName: id.ownerName,
                    tid: id.tid,
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                )
            }
        } catch {
            YamiboLog.download.error("Failed to read manga offline download membership for tid \(id.tid): \(error)")
            return nil
        }
    }

    func mangaDownloadMemberships(forOwnerName ownerName: String) async -> [MangaDownloadMembership] {
        await ensureQueueRecoveredBestEffort()
        guard let ownerName = ownerName.nilIfBlank else { return [] }
        do {
            return try await database.read { db in
                try Self.memberships(
                    ownerName: ownerName,
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                )
            }
        } catch {
            YamiboLog.download.error("Failed to read manga offline download memberships for owner \(ownerName): \(error)")
            return []
        }
    }

    func allMangaDownloadMemberships() async -> [MangaDownloadMembership] {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                try Self.allMangaMemberships(
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                )
            }
        } catch {
            YamiboLog.download.error("Failed to read all manga offline download memberships: \(error)")
            return []
        }
    }

    func saveMangaDownloadMembership(_ membership: MangaDownloadMembership) async throws {
        try await ensureQueueRecovered()
        var writtenPayload: MangaSourcePagePayload?
        do {
            let normalized = try Self.normalizedMembership(membership)
            let payload = try writeMangaSourcePagePayload(for: normalized)
            writtenPayload = payload
            try await database.write { db in
                let previousFiles = try Self.mangaSourcePageFileNames(
                    ownerName: normalized.ownerName,
                    tid: normalized.tid,
                    in: db
                )
                try Self.save(
                    normalized,
                    sourceFileName: payload.fileName,
                    sourceFingerprint: payload.fingerprint,
                    sourceByteCount: payload.byteCount,
                    in: db
                )
                if try Self.isMembershipComplete(normalized, fileManager: fileManager, imagesDirectory: imagesDirectory, in: db) {
                    try Self.deleteWork(ownerName: normalized.ownerName, tid: normalized.tid, in: db)
                }
                try Self.removeUnreferencedMangaSourcePageFiles(
                    candidateFileNames: previousFiles.subtracting([payload.fileName]),
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    in: db
                )
            }
            notifyDownloadDidChange()
        } catch {
            if let writtenPayload, !writtenPayload.fileExistedBeforeWrite {
                do {
                    try fileManager.removeItem(
                        at: mangaSourcePagesDirectory.appendingPathComponent(writtenPayload.fileName, isDirectory: false)
                    )
                } catch {
                    YamiboLog.download.warning("Failed to roll back manga source page file \(writtenPayload.fileName) after save failure: \(error)")
                }
            }
            throw downloadPersistenceError(from: error)
        }
    }

    func removeMangaDownloadMembership(ownerName: String, tid: String) async throws {
        try await ensureQueueRecovered()
        guard let id = normalizedID(ownerName: ownerName, tid: tid) else { return }
        do {
            try await database.write { db in
                let canceled = try Self.rawWork(readerKind: .manga, ownerKey: id.ownerName, entryKey: id.tid, in: db)
                let candidateSourceFiles = try Self.mangaSourcePageFileNames(ownerName: id.ownerName, tid: id.tid, in: db)
                let candidateImageURLs = try Self.imageURLs(
                    table: "download_manga_entry_images",
                    ownerName: id.ownerName,
                    tid: id.tid,
                    in: db
                ) + (canceled.map { $0.targetImageURLs + $0.completedImageURLs } ?? [])
                try Self.deleteMembership(ownerName: id.ownerName, tid: id.tid, in: db)
                try Self.deleteWork(ownerName: id.ownerName, tid: id.tid, in: db)
                try Self.removeUnreferencedImages(
                    candidateImageURLs: candidateImageURLs,
                    fileManager: fileManager,
                    imagesDirectory: imagesDirectory,
                    in: db
                )
                try Self.removeUnreferencedMangaSourcePageFiles(
                    candidateFileNames: candidateSourceFiles,
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    in: db
                )
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func removeMangaDownloadMemberships(forOwnerName ownerName: String) async throws {
        try await ensureQueueRecovered()
        guard let ownerName = ownerName.nilIfBlank else { return }
        do {
            try await database.write { db in
                let ownerName = try Self.canonicalMangaOwnerKey(ownerName, in: db)
                let candidateSourceFiles = try Self.mangaSourcePageFileNames(ownerName: ownerName, in: db)
                let removedImageURLs = try Self.mangaEntryImageURLs(ownerName: ownerName, in: db)
                let canceled = try Self.rawWorks(readerKind: .manga, ownerKey: ownerName, in: db)
                try db.execute(sql: "DELETE FROM download_manga_entries WHERE owner_name = ?", arguments: [ownerName])
                try db.execute(
                    sql: "DELETE FROM download_works WHERE reader_kind = ? AND owner_name = ?",
                    arguments: [Self.mangaReaderKind, ownerName]
                )
                try Self.removeUnreferencedImages(
                    candidateImageURLs: removedImageURLs + canceled.flatMap { $0.targetImageURLs + $0.completedImageURLs },
                    fileManager: fileManager,
                    imagesDirectory: imagesDirectory,
                    in: db
                )
                try Self.removeUnreferencedMangaSourcePageFiles(
                    candidateFileNames: candidateSourceFiles,
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    in: db
                )
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }


    func enqueueMangaDownloadWork(_ request: MangaDownloadWorkRequest) async throws -> MangaDownloadEnqueueResult {
        try await ensureQueueRecovered()
        do {
            let result: MangaDownloadEnqueueResult = try await database.write { db in
                guard request.ownerName.nilIfBlank != nil else {
                    throw YamiboPersistenceError(context: "Offline download owner is empty")
                }
                guard request.tid.nilIfBlank != nil else {
                    throw YamiboPersistenceError(context: "Chapter tid is empty")
                }
                let normalizedRequest = MangaDownloadWorkRequest(
                    ownerName: try Self.canonicalMangaOwnerKey(request.ownerName, in: db),
                    tid: request.tid,
                    chapterTitle: request.chapterTitle,
                    targetImageURLs: request.targetImageURLs
                )
                if let membership = try Self.membership(
                    ownerName: normalizedRequest.ownerName,
                    tid: normalizedRequest.tid,
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                ),
                   try Self.isMembershipComplete(membership, fileManager: fileManager, imagesDirectory: imagesDirectory, in: db) {
                    return .alreadyDownloaded(membership)
                }
                if let work = try Self.rawWork(readerKind: .manga, ownerKey: normalizedRequest.ownerName, entryKey: normalizedRequest.tid, in: db) {
                    return .alreadyQueued(try Self.queueWorkProjection(from: work, in: db))
                }
                return .enqueued(try Self.enqueueNewWork(
                    readerKind: .manga,
                    ownerKey: normalizedRequest.ownerName,
                    ownerTitle: try Self.mangaOwnerTitle(normalizedRequest.ownerName, in: db),
                    entryKey: normalizedRequest.tid,
                    title: normalizedRequest.chapterTitle,
                    targetImageURLs: normalizedRequest.targetImageURLs,
                    retainsInlineImages: false,
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

    func clearDownloadQueue() async throws {
        try await ensureQueueRecovered()
        try await database.write { db in
            try db.execute(sql: "DELETE FROM download_works")
            try Self.setQueueRunState(.paused, in: db)
        }
        notifyDownloadDidChange()
    }

    func downloadQueueRunState() async throws -> DownloadQueueRunState {
        try await ensureQueueRecovered()
        do {
            return try await database.read { db in
                try Self.queueRunState(in: db)
            }
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func setDownloadQueueRunState(_ state: DownloadQueueRunState) async throws {
        try await ensureQueueRecovered()
        do {
            try await database.write { db in
                try Self.setQueueRunState(state, in: db)
                if state == .paused {
                    try Self.pauseRunningDownloadWorks(in: db)
                }
            }
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func mangaDownloadState(ownerName: String, tid: String) async -> MangaDownloadState {
        await ensureQueueRecoveredBestEffort()
        guard let id = normalizedID(ownerName: ownerName, tid: tid) else { return .notDownloaded }
        do {
            return try await database.read { db in
                if let membership = try Self.membership(
                    ownerName: id.ownerName,
                    tid: id.tid,
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    sourcePageCache: sourcePageCache,
                    in: db
                ),
                   try Self.isMembershipComplete(membership, fileManager: fileManager, imagesDirectory: imagesDirectory, in: db) {
                    return .downloaded
                }
                if try Self.rawWork(readerKind: .manga, ownerKey: id.ownerName, entryKey: id.tid, in: db) != nil {
                    return .downloading
                }
                return .notDownloaded
            }
        } catch {
            YamiboLog.download.error("Failed to read manga offline download state for tid \(id.tid): \(error)")
            return .notDownloaded
        }
    }

    /// The panel needs chapter state, not queue image projections. Read only this
    /// owner's metadata and reuse validated files until their directory changes.
    func mangaDownloadStates(ownerName: String) async -> [String: MangaDownloadState] {
        await ensureQueueRecoveredBestEffort()
        guard let ownerName = ownerName.nilIfBlank else { return [:] }
        let previous = mangaOwnerStateCache[ownerName]
        do {
            let result = try await database.read { db -> MangaOwnerStateCache in
                let canonicalOwner = try Self.canonicalMangaOwnerKey(ownerName, in: db)
                let entries = try Row.fetchAll(db, sql: "SELECT * FROM download_manga_entries WHERE owner_name = ? ORDER BY tid", arguments: [canonicalOwner])
                let images = try Row.fetchAll(db, sql: """
                    SELECT i.tid, i.image_url, a.file_name
                    FROM download_manga_entry_images i
                    LEFT JOIN download_image_assets a ON a.image_url = i.image_url
                    WHERE i.owner_name = ? ORDER BY i.tid, i.image_url
                    """, arguments: [canonicalOwner])
                let works = try Row.fetchAll(db, sql: "SELECT tid FROM download_works WHERE reader_kind = ? AND owner_name = ? ORDER BY tid", arguments: [DownloadReaderKind.manga.rawValue, canonicalOwner])
                let imageStamp = (try? fileManager.attributesOfItem(atPath: imagesDirectory.path)[.modificationDate]) as? Date
                let sourceStamp = (try? fileManager.attributesOfItem(atPath: mangaSourcePagesDirectory.path)[.modificationDate]) as? Date
                // Row descriptions contain every persisted entry field, including
                // schema/fingerprint. No source HTML or per-image queries here.
                let signature = [canonicalOwner] + entries.map { String(describing: $0) }
                    + images.map { String(describing: $0) } + works.map { String(describing: $0) }
                if let previous, previous.signature == signature,
                   imageStamp != nil, sourceStamp != nil,
                   previous.imageStamp == imageStamp, previous.sourceStamp == sourceStamp {
                    return previous
                }
                var states: [String: MangaDownloadState] = [:]
                for work in works { states[work["tid"] as String] = .downloading }
                let imagesByTID = Dictionary(grouping: images, by: { $0["tid"] as String })
                for entry in entries {
                    let tid: String = entry["tid"]
                    guard Self.validSourcePage(
                        fileName: entry["source_page_file_name"], schemaVersion: entry["source_page_schema_version"],
                        fingerprint: entry["source_page_fingerprint"], byteCount: entry["byte_count"], tid: tid,
                        fileManager: fileManager, mangaSourcePagesDirectory: mangaSourcePagesDirectory, sourcePageCache: sourcePageCache
                    ) != nil, let imageRows = imagesByTID[tid], !imageRows.isEmpty else { continue }
                    if imageRows.allSatisfy({ row in
                        guard let name = row["file_name"] as String? else { return false }
                        return fileManager.fileExists(atPath: imagesDirectory.appendingPathComponent(name).path)
                    }) { states[tid] = .downloaded }
                }
                return MangaOwnerStateCache(signature: signature, imageStamp: imageStamp, sourceStamp: sourceStamp, states: states)
            }
            if mangaOwnerStateCache.count >= 32 { mangaOwnerStateCache.removeAll(keepingCapacity: true) }
            mangaOwnerStateCache[ownerName] = result
            return result.states
        } catch {
            YamiboLog.download.error("Failed to read manga owner download states: \(error)")
            return [:]
        }
    }

    func clearAll() async throws {
        do {
            try await database.write { db in
                for table in ForumAttachmentDownloadSchema.tables + ReaderDatabaseSchema.downloadTableNamesInDeletionOrder {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            }
            if fileManager.fileExists(atPath: baseDirectory.path) {
                try fileManager.removeItem(at: baseDirectory)
            }
            didRecoverQueueState = true
            notifyDownloadDidChange()
        } catch {
            throw downloadPersistenceError(from: error)
        }
    }

    func totalDiskUsageBytes() async -> Int {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                let imageBytes = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(byte_count), 0) FROM download_image_assets"
                ) ?? 0
                let novelBytes = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(byte_count), 0) FROM download_novel_entries"
                ) ?? 0
                let mangaSourcePageBytes = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(byte_count), 0) FROM download_manga_entries"
                ) ?? 0
                let attachmentBytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM download_attachment_entries") ?? 0
                return imageBytes + novelBytes + mangaSourcePageBytes + attachmentBytes
            }
        } catch {
            YamiboLog.download.error("Failed to read total offline download disk usage: \(error)")
            return 0
        }
    }

    func recoverQueueStateAfterRestart() async throws {
        if let queueRecoveryTask {
            try await queueRecoveryTask.value
            return
        }
        guard !didRecoverQueueState else { return }
        let task = Task { [database] in
            try await database.write { db in
                if try Self.queueRunState(in: db) == .running {
                    try Self.setQueueRunState(.paused, in: db)
                    try Self.pauseRunningDownloadWorks(in: db)
                }
            }
        }
        queueRecoveryTask = task
        defer { queueRecoveryTask = nil }
        do {
            try await task.value
            didRecoverQueueState = true
        } catch {
            YamiboLog.download.error("Failed to recover offline download queue state after restart: \(error)")
            throw error
        }
    }

    // Every store entry point must run the one-time post-restart queue
    // recovery before touching queue state. The two wrappers below replace the
    // per-method `try`/`try?` prefix boilerplate so that "does this operation
    // tolerate a failed recovery?" is a visible, named decision at each call
    // site instead of a one-character difference. Concurrent callers await the
    // same recovery. Only a successful recovery is remembered, allowing a later
    // explicit refresh to retry after a transient persistence failure.
    //
    // They are internal rather than private only because the call sites live
    // in this actor's sibling extension files; the actor itself is internal,
    // so nothing is added to the package's public surface.

    /// For operations whose contract is to throw on persistence problems
    /// (queue mutations, saves, removals): a failed recovery aborts the
    /// operation before it can act on unrecovered queue state, and the error
    /// propagates to the caller exactly as the previous inline
    /// `try await recoverQueueStateAfterRestart()` did.
    func ensureQueueRecovered() async throws {
        try await recoverQueueStateAfterRestart()
    }

    /// Best-effort variant for regenerable download accessors without an error
    /// channel. Queue and management queries must use the throwing variant.
    func ensureQueueRecoveredBestEffort() async {
        try? await recoverQueueStateAfterRestart()
    }

    private func normalizedID(ownerName: String, tid: String) -> MangaDownloadMembershipID? {
        guard let ownerName = ownerName.nilIfBlank,
              let tid = tid.nilIfBlank else {
            return nil
        }
        return MangaDownloadMembershipID(ownerName: ownerName, tid: tid)
    }

    public nonisolated func notifyIdentityMigrationCommitted() {
        notifyDownloadDidChange()
    }

    nonisolated func notifyDownloadDidChange() {
        updateNotifier.post(())
    }

    func ensureBaseDirectoryExists() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try Self.createBackupExcludedDirectory(at: baseDirectory, fileManager: fileManager)
        }
    }

    /// `clearAll()` deletes the whole base directory, so every path that
    /// recreates it must restore the backup exclusion or fresh downloads would
    /// silently re-enter iCloud/iTunes backups until the next launch. A failed
    /// marker write is logged instead of thrown: it must not fail the download
    /// that triggered the directory creation.
    static func createBackupExcludedDirectory(at directory: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directory = directory
        do {
            try directory.setResourceValues(resourceValues)
        } catch {
            YamiboLog.download.error("Failed to exclude the offline download directory from backups: \(error)")
        }
    }

    func ensureNovelSourcePagesDirectoryExists() throws {
        try ensureBaseDirectoryExists()
        if !fileManager.fileExists(atPath: novelSourcePagesDirectory.path) {
            try fileManager.createDirectory(at: novelSourcePagesDirectory, withIntermediateDirectories: true)
        }
    }

    func ensureMangaSourcePagesDirectoryExists() throws {
        try ensureBaseDirectoryExists()
        if !fileManager.fileExists(atPath: mangaSourcePagesDirectory.path) {
            try fileManager.createDirectory(at: mangaSourcePagesDirectory, withIntermediateDirectories: true)
        }
    }

    private func writeMangaSourcePagePayload(for membership: MangaDownloadMembership) throws -> MangaSourcePagePayload {
        try ensureMangaSourcePagesDirectoryExists()
        let data = try Self.encodeSourcePageData(membership.sourcePage)
        let fileName = mangaSourcePageFileName(ownerName: membership.ownerName, tid: membership.tid)
        let fileURL = mangaSourcePagesDirectory.appendingPathComponent(fileName, isDirectory: false)
        let fileExistedBeforeWrite = fileManager.fileExists(atPath: fileURL.path)
        try data.write(to: fileURL, options: [.atomic])
        return MangaSourcePagePayload(
            fileName: fileName,
            fingerprint: Self.sourcePageFingerprint(for: data),
            byteCount: data.count,
            fileExistedBeforeWrite: fileExistedBeforeWrite
        )
    }

    private func mangaSourcePageFileName(ownerName: String, tid: String) -> String {
        "source_\(sha256Hex([ownerName, tid].joined(separator: "\u{1F}"))).json"
    }

    private static func normalizedMembership(_ membership: MangaDownloadMembership) throws -> MangaDownloadMembership {
        guard membership.ownerName.nilIfBlank != nil else {
            throw YamiboPersistenceError(context: "Offline download owner is empty")
        }
        guard membership.tid.nilIfBlank != nil else {
            throw YamiboPersistenceError(context: "Chapter tid is empty")
        }
        guard membership.sourcePage.thread.tid == membership.tid else {
            throw YamiboPersistenceError(context: "Manga offline source page does not match chapter tid")
        }
        return MangaDownloadMembership(
            ownerName: membership.ownerName,
            tid: membership.tid,
            chapterTitle: membership.chapterTitle,
            imageURLs: membership.imageURLs,
            sourcePage: membership.sourcePage,
            createdAt: membership.createdAt
        )
    }

    private static func save(
        _ membership: MangaDownloadMembership,
        sourceFileName: String,
        sourceFingerprint: String,
        sourceByteCount: Int,
        in db: Database
    ) throws {
        var membership = membership
        membership.ownerName = try canonicalMangaOwnerKey(membership.ownerName, in: db)
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO download_manga_entries
            (owner_name, tid, chapter_title, source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                membership.ownerName,
                membership.tid,
                membership.chapterTitle,
                sourceFileName,
                1,
                sourceFingerprint,
                sourceByteCount,
                downloadTimeInterval(from: membership.createdAt)
            ]
        )
        try db.execute(
            sql: "DELETE FROM download_manga_entry_images WHERE owner_name = ? AND tid = ?",
            arguments: [membership.ownerName, membership.tid]
        )
        for (index, imageURL) in membership.imageURLs.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO download_manga_entry_images (owner_name, tid, manual_order, image_url)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [membership.ownerName, membership.tid, index, imageURL.absoluteString]
            )
        }
    }

    // Diffs against what's already stored instead of DELETE-then-reinsert-everything, since
    // callers (e.g. per-image progress updates) invoke this repeatedly for the same
    // (owner, tid) with a list that mostly repeats its previous contents; a full rewrite
    // each time is O(n) per call and O(n^2) across a whole chapter's download.
    static func replaceImageList(
        table: String,
        readerKind: String,
        ownerName: String,
        tid: String,
        imageURLs: [URL],
        manualOrders: [Int]? = nil,
        in db: Database
    ) throws {
        var desiredByPosition: [Int: String] = [:]
        for (index, imageURL) in imageURLs.enumerated() {
            desiredByPosition[manualOrders?[index] ?? index] = imageURL.absoluteString
        }

        var existingByPosition: [Int: String] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT manual_order, image_url FROM \(table) WHERE reader_kind = ? AND owner_name = ? AND tid = ?",
            arguments: [readerKind, ownerName, tid]
        ) {
            existingByPosition[row["manual_order"] as Int] = row["image_url"] as String
        }

        guard existingByPosition != desiredByPosition else { return }

        for position in existingByPosition.keys where desiredByPosition[position] != existingByPosition[position] {
            try db.execute(
                sql: "DELETE FROM \(table) WHERE reader_kind = ? AND owner_name = ? AND tid = ? AND manual_order = ?",
                arguments: [readerKind, ownerName, tid, position]
            )
        }
        for (position, imageURLString) in desiredByPosition where existingByPosition[position] != imageURLString {
            try db.execute(
                sql: """
                INSERT INTO \(table) (reader_kind, owner_name, tid, manual_order, image_url)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [readerKind, ownerName, tid, position, imageURLString]
            )
        }
    }

    /// A scoped image lookup does not need to hydrate the chapter's image list.
    /// Keep the source-page validity gate used by full membership reads.
    static func mangaOfflineImageFileName(
        imageURLString: String,
        ownerName: String,
        tid: String,
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>,
        in db: Database
    ) throws -> String? {
        guard let ownerName = ownerName.nilIfBlank, let tid = tid.nilIfBlank else { return nil }
        let canonicalOwnerName = try canonicalMangaOwnerKey(ownerName, in: db)
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT entries.tid, entries.source_page_file_name, entries.source_page_schema_version,
                entries.source_page_fingerprint, entries.byte_count, assets.file_name
            FROM download_manga_entry_images AS images
            JOIN download_manga_entries AS entries
                ON entries.owner_name = images.owner_name AND entries.tid = images.tid
            JOIN download_image_assets AS assets ON assets.image_url = images.image_url
            WHERE images.image_url = ? AND images.owner_name = ? AND images.tid = ?
            LIMIT 1
            """,
            arguments: [imageURLString, canonicalOwnerName, tid]
        ), validSourcePage(
            fileName: row["source_page_file_name"],
            schemaVersion: row["source_page_schema_version"],
            fingerprint: row["source_page_fingerprint"],
            byteCount: row["byte_count"],
            tid: row["tid"],
            fileManager: fileManager,
            mangaSourcePagesDirectory: mangaSourcePagesDirectory,
            sourcePageCache: sourcePageCache
        ) != nil else { return nil }
        return row["file_name"]
    }

    static func membership(
        ownerName: String,
        tid: String,
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>,
        in db: Database
    ) throws -> MangaDownloadMembership? {
        let ownerName = try canonicalMangaOwnerKey(ownerName, in: db)
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT owner_name, tid, chapter_title, source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at
            FROM download_manga_entries
            WHERE owner_name = ? AND tid = ?
            """,
            arguments: [ownerName, tid]
        ) else {
            return nil
        }
        return try membership(
            from: row,
            fileManager: fileManager,
            mangaSourcePagesDirectory: mangaSourcePagesDirectory,
            sourcePageCache: sourcePageCache,
            in: db
        )
    }

    private static func memberships(
        ownerName: String,
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>,
        in db: Database
    ) throws -> [MangaDownloadMembership] {
        let ownerName = try canonicalMangaOwnerKey(ownerName, in: db)
        return try Row.fetchAll(
            db,
            sql: """
            SELECT owner_name, tid, chapter_title, source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at
            FROM download_manga_entries
            WHERE owner_name = ?
            ORDER BY owner_name ASC, tid ASC
            """,
            arguments: [ownerName]
        ).compactMap {
            try membership(
                from: $0,
                fileManager: fileManager,
                mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                sourcePageCache: sourcePageCache,
                in: db
            )
        }
    }

    static func allMangaMemberships(
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>,
        in db: Database
    ) throws -> [MangaDownloadMembership] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT owner_name, tid, chapter_title, source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at
            FROM download_manga_entries
            ORDER BY owner_name ASC, tid ASC
            """
        ).compactMap {
            try membership(
                from: $0,
                fileManager: fileManager,
                mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                sourcePageCache: sourcePageCache,
                in: db
            )
        }
    }

    private static func membership(
        from row: Row,
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>,
        in db: Database
    ) throws -> MangaDownloadMembership? {
        let tid = row["tid"] as String
        guard let sourcePage = validSourcePage(
            fileName: row["source_page_file_name"] as String?,
            schemaVersion: row["source_page_schema_version"] as Int?,
            fingerprint: row["source_page_fingerprint"] as String?,
            byteCount: row["byte_count"] as Int?,
            tid: tid,
            fileManager: fileManager,
            mangaSourcePagesDirectory: mangaSourcePagesDirectory,
            sourcePageCache: sourcePageCache
        ) else {
            return nil
        }
        return MangaDownloadMembership(
            ownerName: row["owner_name"],
            tid: tid,
            chapterTitle: row["chapter_title"],
            imageURLs: try imageURLs(
                table: "download_manga_entry_images",
                ownerName: row["owner_name"],
                tid: tid,
                in: db
            ),
            sourcePage: sourcePage,
            createdAt: downloadOptionalDate(from: row["created_at"] as Double?) ?? Date(timeIntervalSince1970: 0)
        )
    }

    static func imageURLs(
        table: String,
        readerKind: String? = nil,
        ownerName: String,
        tid: String,
        in db: Database
    ) throws -> [URL] {
        let ownerName = readerKind == "manga" || table == "download_manga_entry_images"
            ? try canonicalMangaOwnerKey(ownerName, in: db) : ownerName
        if let readerKind {
            return try String.fetchAll(
                db,
                sql: """
                SELECT image_url
                FROM \(table)
                WHERE reader_kind = ? AND owner_name = ? AND tid = ?
                ORDER BY manual_order ASC
                """,
                arguments: [readerKind, ownerName, tid]
            ).compactMap(URL.init(string:))
        }

        return try String.fetchAll(
            db,
            sql: """
            SELECT image_url
            FROM \(table)
            WHERE owner_name = ? AND tid = ?
            ORDER BY manual_order ASC
            """,
            arguments: [ownerName, tid]
        ).compactMap(URL.init(string:))
    }

    static func mangaEntryImageURLs(ownerName: String, in db: Database) throws -> [URL] {
        let ownerName = try canonicalMangaOwnerKey(ownerName, in: db)
        return try String.fetchAll(
            db,
            sql: """
            SELECT image_url
            FROM download_manga_entry_images
            WHERE owner_name = ?
            ORDER BY owner_name ASC, tid ASC, manual_order ASC
            """,
            arguments: [ownerName]
        ).compactMap(URL.init(string:))
    }

    static func mangaEntryByteCount(ownerName: String, tid: String, in db: Database) throws -> Int {
        let ownerName = try canonicalMangaOwnerKey(ownerName, in: db)
        return try Int.fetchOne(
            db,
            sql: "SELECT byte_count FROM download_manga_entries WHERE owner_name = ? AND tid = ?",
            arguments: [ownerName, tid]
        ) ?? 0
    }

    private static func deleteMembership(ownerName: String, tid: String, in db: Database) throws {
        let ownerName = try canonicalMangaOwnerKey(ownerName, in: db)
        try db.execute(
            sql: "DELETE FROM download_manga_entries WHERE owner_name = ? AND tid = ?",
            arguments: [ownerName, tid]
        )
    }

    static func deleteWork(ownerName: String, tid: String, in db: Database) throws {
        try deleteWork(readerKind: mangaReaderKind, ownerName: ownerName, tid: tid, in: db)
    }

    static func deleteWork(readerKind: String, ownerName: String, tid: String, in db: Database) throws {
        let ownerName = readerKind == "manga" ? try canonicalMangaOwnerKey(ownerName, in: db) : ownerName
        try db.execute(
            sql: "DELETE FROM download_works WHERE reader_kind = ? AND owner_name = ? AND tid = ?",
            arguments: [readerKind, ownerName, tid]
        )
    }

    private static func encodeSourcePageData(_ sourcePage: ForumThreadPage) throws -> Data {
        do {
            return try JSONEncoder().encode(sourcePage)
        } catch {
            throw YamiboPersistenceError(context: "Failed to encode manga offline source page", underlying: error)
        }
    }

    private static func validSourcePage(
        fileName: String?,
        schemaVersion: Int?,
        fingerprint: String?,
        byteCount: Int?,
        tid: String,
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>
    ) -> ForumThreadPage? {
        guard let fileName = fileName?.nilIfBlank,
              schemaVersion == 1,
              let fingerprint = fingerprint?.nilIfBlank,
              let byteCount else {
            return nil
        }
        let fileURL = mangaSourcePagesDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Keying on (tid, fileName, fingerprint, byteCount) means a legitimately replaced
        // source page file (different content -> different fingerprint/byteCount) naturally
        // misses the download without any explicit invalidation.
        let cacheKey = sourcePageCacheKey(tid: tid, fileName: fileName, fingerprint: fingerprint, byteCount: byteCount) as NSString
        if let cached = sourcePageCache.object(forKey: cacheKey) {
            return cached.sourcePage
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        guard byteCount == data.count,
              sourcePageFingerprint(for: data) == fingerprint else {
            YamiboLog.download.error("Manga source page file \(fileName) failed fingerprint/byte-count check for tid \(tid); treating download entry as corrupted")
            return nil
        }
        guard let sourcePage = try? JSONDecoder().decode(ForumThreadPage.self, from: data),
              sourcePage.thread.tid == tid else {
            YamiboLog.download.error("Failed to decode manga source page file \(fileName) or tid mismatch for tid \(tid)")
            return nil
        }
        sourcePageCache.setObject(SourcePageCacheEntry(sourcePage: sourcePage), forKey: cacheKey)
        return sourcePage
    }

    private static func sourcePageCacheKey(tid: String, fileName: String, fingerprint: String, byteCount: Int) -> String {
        "\(tid)#\(fileName)#\(fingerprint)#\(byteCount)"
    }

    private static func sourcePageFingerprint(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func mangaSourcePageFileNames(ownerName: String, tid: String, in db: Database) throws -> Set<String> {
        let ownerName = try canonicalMangaOwnerKey(ownerName, in: db)
        let fileNames = try String.fetchAll(
            db,
            sql: """
            SELECT source_page_file_name
            FROM download_manga_entries
            WHERE owner_name = ? AND tid = ? AND source_page_file_name IS NOT NULL
            """,
            arguments: [ownerName, tid]
        )
        return Set(fileNames.compactMap(\.nilIfBlank))
    }

    static func mangaSourcePageFileNames(ownerName: String, in db: Database) throws -> Set<String> {
        let ownerName = try canonicalMangaOwnerKey(ownerName, in: db)
        let fileNames = try String.fetchAll(
            db,
            sql: """
            SELECT source_page_file_name
            FROM download_manga_entries
            WHERE owner_name = ? AND source_page_file_name IS NOT NULL
            """,
            arguments: [ownerName]
        )
        return Set(fileNames.compactMap(\.nilIfBlank))
    }

    static func removeUnreferencedMangaSourcePageFiles(
        candidateFileNames: Set<String>,
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        in db: Database
    ) throws {
        guard !candidateFileNames.isEmpty else { return }
        let referenced = Set(try String.fetchAll(
            db,
            sql: "SELECT source_page_file_name FROM download_manga_entries WHERE source_page_file_name IS NOT NULL"
        ).compactMap(\.nilIfBlank))
        for fileName in candidateFileNames where !referenced.contains(fileName) {
            do {
                try fileManager.removeItem(at: mangaSourcePagesDirectory.appendingPathComponent(fileName, isDirectory: false))
            } catch {
                YamiboLog.download.error("Failed to remove unreferenced manga source page file \(fileName): \(error)")
            }
        }
    }

    /// Global max keeps per-kind enqueue order (a new work sorts after every
    /// existing one) while `download_works_insertion_idx` answers it in
    /// O(log n) — a per-kind MAX would scan that kind's rows.
    static func nextQueueInsertionIndex(in db: Database) throws -> Int {
        (try Int.fetchOne(
            db,
            sql: "SELECT MAX(insertion_index) FROM download_works"
        ) ?? 0) + 1
    }

    private static func pauseRunningDownloadWorks(in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE download_works
            SET state = ?, current_bytes_per_second = 0
            WHERE state = ?
            """,
            arguments: [
                DownloadWorkState.paused.rawValue,
                DownloadWorkState.running.rawValue
            ]
        )
    }

    private static func queueRunState(in db: Database) throws -> DownloadQueueRunState {
        guard let rawValue = try String.fetchOne(
            db,
            sql: "SELECT value FROM download_queue_state WHERE key = ?",
            arguments: ["run_state"]
        ) else {
            return .paused
        }
        return DownloadQueueRunState(rawValue: rawValue) ?? .paused
    }

    private static func setQueueRunState(_ state: DownloadQueueRunState, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO download_queue_state (key, value)
            VALUES (?, ?)
            """,
            arguments: ["run_state", state.rawValue]
        )
    }

    private static func defaultBaseDirectory(fileManager: FileManager) -> URL {
        YamiboDatabase.defaultRootDirectory(fileManager: fileManager)
            .appendingPathComponent("downloads", isDirectory: true)
    }

}

extension DownloadStore: DownloadStoreCore {}

private struct MangaSourcePagePayload {
    var fileName: String
    var fingerprint: String
    var byteCount: Int
    var fileExistedBeforeWrite: Bool
}

final class SourcePageCacheEntry {
    let sourcePage: ForumThreadPage

    init(sourcePage: ForumThreadPage) {
        self.sourcePage = sourcePage
    }
}

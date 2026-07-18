import CryptoKit
import Foundation
@preconcurrency import GRDB

actor OfflineCacheStore {
    let database: DatabasePool
    nonisolated(unsafe) let fileManager: FileManager
    private let baseDirectory: URL
    let imagesDirectory: URL
    let mangaSourcePagesDirectory: URL
    let novelSourcePagesDirectory: URL
    private let updateNotifier = OfflineCacheUpdateNotifier()
    private var didRecoverQueueState = false
    private static let mangaReaderKind = "manga"
    nonisolated(unsafe) let sourcePageCache: NSCache<NSString, SourcePageCacheEntry> = {
        let cache = NSCache<NSString, SourcePageCacheEntry>()
        cache.countLimit = 128
        return cache
    }()

    init(
        databasePool: DatabasePool? = nil,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.database = databasePool ?? YamiboDatabasePoolResolver.openDefaultPool(storeName: "OfflineCacheStore")
        self.fileManager = fileManager
        let root = baseDirectory ?? Self.defaultBaseDirectory(fileManager: fileManager)
        self.baseDirectory = root
        self.imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        self.mangaSourcePagesDirectory = root.appendingPathComponent("manga-source-pages", isDirectory: true)
        self.novelSourcePagesDirectory = root.appendingPathComponent("novel-source-pages", isDirectory: true)
    }

    nonisolated public func offlineCacheUpdates() -> AsyncStream<Void> {
        updateNotifier.stream()
    }

    func mangaOfflineCacheMembership(ownerName: String, tid: String) async -> MangaOfflineCacheMembership? {
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
            YamiboLog.offlineCache.error("Failed to read manga offline cache membership for tid \(id.tid): \(error)")
            return nil
        }
    }

    func mangaOfflineCacheMemberships(forOwnerName ownerName: String) async -> [MangaOfflineCacheMembership] {
        await ensureQueueRecoveredBestEffort()
        guard let ownerName = ownerName.mangaReaderTrimmedNonEmpty else { return [] }
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
            YamiboLog.offlineCache.error("Failed to read manga offline cache memberships for owner \(ownerName): \(error)")
            return []
        }
    }

    func allMangaOfflineCacheMemberships() async -> [MangaOfflineCacheMembership] {
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
            YamiboLog.offlineCache.error("Failed to read all manga offline cache memberships: \(error)")
            return []
        }
    }

    func saveMangaOfflineCacheMembership(_ membership: MangaOfflineCacheMembership) async throws {
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
            notifyOfflineCacheDidChange()
        } catch {
            if let writtenPayload, !writtenPayload.fileExistedBeforeWrite {
                do {
                    try fileManager.removeItem(
                        at: mangaSourcePagesDirectory.appendingPathComponent(writtenPayload.fileName, isDirectory: false)
                    )
                } catch {
                    YamiboLog.offlineCache.warning("Failed to roll back manga source page file \(writtenPayload.fileName) after save failure: \(error)")
                }
            }
            throw offlineCachePersistenceError(from: error)
        }
    }

    func removeMangaOfflineCacheMembership(ownerName: String, tid: String) async throws {
        try await ensureQueueRecovered()
        guard let id = normalizedID(ownerName: ownerName, tid: tid) else { return }
        do {
            try await database.write { db in
                let canceled = try Self.rawWork(readerKind: .manga, ownerKey: id.ownerName, entryKey: id.tid, in: db)
                let candidateSourceFiles = try Self.mangaSourcePageFileNames(ownerName: id.ownerName, tid: id.tid, in: db)
                let candidateImageURLs = try Self.imageURLs(
                    table: "offline_cache_manga_entry_images",
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
            notifyOfflineCacheDidChange()
        } catch {
            throw offlineCachePersistenceError(from: error)
        }
    }

    func removeMangaOfflineCacheMemberships(forOwnerName ownerName: String) async throws {
        try await ensureQueueRecovered()
        guard let ownerName = ownerName.mangaReaderTrimmedNonEmpty else { return }
        do {
            try await database.write { db in
                let candidateSourceFiles = try Self.mangaSourcePageFileNames(ownerName: ownerName, in: db)
                let removedImageURLs = try Self.mangaEntryImageURLs(ownerName: ownerName, in: db)
                let canceled = try Self.rawWorks(readerKind: .manga, ownerKey: ownerName, in: db)
                try db.execute(sql: "DELETE FROM offline_cache_manga_entries WHERE owner_name = ?", arguments: [ownerName])
                try db.execute(
                    sql: "DELETE FROM offline_cache_works WHERE reader_kind = ? AND owner_name = ?",
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
            notifyOfflineCacheDidChange()
        } catch {
            throw offlineCachePersistenceError(from: error)
        }
    }

    func renameMangaOfflineCacheOwner(from oldOwnerName: String, to newOwnerName: String) async throws {
        try await ensureQueueRecovered()
        guard let oldOwnerName = oldOwnerName.mangaReaderTrimmedNonEmpty,
              let newOwnerName = newOwnerName.mangaReaderTrimmedNonEmpty,
              oldOwnerName != newOwnerName else {
            return
        }
        var writtenPayloads: [MangaSourcePagePayload] = []
        do {
            let (memberships, works) = try await database.read { db in
                try (
                    Self.memberships(
                        ownerName: oldOwnerName,
                        fileManager: fileManager,
                        mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                        sourcePageCache: sourcePageCache,
                        in: db
                    ),
                    Self.rawWorks(readerKind: .manga, ownerKey: oldOwnerName, in: db)
                )
            }
            guard !memberships.isEmpty || !works.isEmpty else { return }
            let renamedMemberships = try memberships.map { membership -> (membership: MangaOfflineCacheMembership, payload: MangaSourcePagePayload) in
                let renamed = MangaOfflineCacheMembership(
                    ownerName: newOwnerName,
                    tid: membership.tid,
                    chapterTitle: membership.chapterTitle,
                    imageURLs: membership.imageURLs,
                    sourcePage: membership.sourcePage,
                    createdAt: membership.createdAt
                )
                let payload = try writeMangaSourcePagePayload(for: renamed)
                writtenPayloads.append(payload)
                return (renamed, payload)
            }
            try await database.write { db in
                let candidateSourceFiles = try Self.mangaSourcePageFileNames(ownerName: oldOwnerName, in: db)
                try db.execute(sql: "DELETE FROM offline_cache_manga_entries WHERE owner_name = ?", arguments: [oldOwnerName])
                try db.execute(
                    sql: "DELETE FROM offline_cache_works WHERE reader_kind = ? AND owner_name = ?",
                    arguments: [Self.mangaReaderKind, oldOwnerName]
                )

                for renamed in renamedMemberships {
                    try Self.save(
                        renamed.membership,
                        sourceFileName: renamed.payload.fileName,
                        sourceFingerprint: renamed.payload.fingerprint,
                        sourceByteCount: renamed.payload.byteCount,
                        in: db
                    )
                }
                for work in works {
                    try Self.save(OfflineCacheRawWork(
                        readerKind: .manga,
                        workID: work.workID,
                        ownerKey: newOwnerName,
                        ownerTitle: newOwnerName,
                        entryKey: work.entryKey,
                        title: work.title,
                        targetImageURLs: work.targetImageURLs,
                        completedImageURLs: work.completedImageURLs,
                        retainsInlineImages: work.retainsInlineImages,
                        state: work.state,
                        failureMessage: work.failureMessage,
                        currentBytesPerSecond: work.currentBytesPerSecond,
                        insertionIndex: work.insertionIndex,
                        createdAt: work.createdAt,
                        updatedAt: work.updatedAt
                    ), in: db)
                }
                try Self.removeUnreferencedMangaSourcePageFiles(
                    candidateFileNames: candidateSourceFiles,
                    fileManager: fileManager,
                    mangaSourcePagesDirectory: mangaSourcePagesDirectory,
                    in: db
                )
            }
            notifyOfflineCacheDidChange()
        } catch {
            for payload in writtenPayloads where !payload.fileExistedBeforeWrite {
                do {
                    try fileManager.removeItem(at: mangaSourcePagesDirectory.appendingPathComponent(payload.fileName, isDirectory: false))
                } catch {
                    YamiboLog.offlineCache.warning("Failed to roll back manga source page file \(payload.fileName) after rename failure: \(error)")
                }
            }
            throw offlineCachePersistenceError(from: error)
        }
    }

    func enqueueMangaOfflineCacheWork(_ request: MangaOfflineCacheWorkRequest) async throws -> MangaOfflineCacheEnqueueResult {
        try await ensureQueueRecovered()
        do {
            let result: MangaOfflineCacheEnqueueResult = try await database.write { db in
                guard request.ownerName.mangaReaderTrimmedNonEmpty != nil else {
                    throw YamiboPersistenceError(context: "Offline cache owner is empty")
                }
                guard request.tid.mangaReaderTrimmedNonEmpty != nil else {
                    throw YamiboPersistenceError(context: "Chapter tid is empty")
                }
                let normalizedRequest = MangaOfflineCacheWorkRequest(
                    ownerName: request.ownerName,
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
                    return .alreadyCached(membership)
                }
                if let work = try Self.rawWork(readerKind: .manga, ownerKey: normalizedRequest.ownerName, entryKey: normalizedRequest.tid, in: db) {
                    return .alreadyQueued(Self.queueWorkProjection(from: work))
                }
                let work = OfflineCacheRawWork(
                    readerKind: .manga,
                    workID: UUID().uuidString,
                    ownerKey: normalizedRequest.ownerName,
                    ownerTitle: normalizedRequest.ownerName,
                    entryKey: normalizedRequest.tid,
                    title: normalizedRequest.chapterTitle,
                    targetImageURLs: normalizedRequest.targetImageURLs,
                    completedImageURLs: [],
                    retainsInlineImages: false,
                    state: .queued,
                    failureMessage: nil,
                    currentBytesPerSecond: 0,
                    insertionIndex: try Self.nextQueueInsertionIndex(in: db),
                    createdAt: Date(),
                    updatedAt: Date()
                )
                try Self.save(work, in: db)
                return .enqueued(Self.queueWorkProjection(from: work))
            }
            if result.enqueuedWork != nil {
                notifyOfflineCacheDidChange()
            }
            return result
        } catch {
            throw offlineCachePersistenceError(from: error)
        }
    }

    func clearOfflineCacheQueue() async throws {
        try await ensureQueueRecovered()
        try await database.write { db in
            try db.execute(sql: "DELETE FROM offline_cache_works")
            try Self.setQueueRunState(.paused, in: db)
        }
        notifyOfflineCacheDidChange()
    }

    func offlineCacheQueueRunState() async -> OfflineCacheQueueRunState {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                try Self.queueRunState(in: db)
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to read offline cache queue run state: \(error)")
            return .paused
        }
    }

    func setOfflineCacheQueueRunState(_ state: OfflineCacheQueueRunState) async throws {
        didRecoverQueueState = true
        do {
            try await database.write { db in
                try Self.setQueueRunState(state, in: db)
                if state == .paused {
                    try Self.pauseRunningOfflineCacheWorks(in: db)
                }
            }
            notifyOfflineCacheDidChange()
        } catch {
            throw offlineCachePersistenceError(from: error)
        }
    }

    func mangaOfflineCacheState(ownerName: String, tid: String) async -> MangaOfflineCacheState {
        await ensureQueueRecoveredBestEffort()
        guard let id = normalizedID(ownerName: ownerName, tid: tid) else { return .uncached }
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
                    return .cached
                }
                if try Self.rawWork(readerKind: .manga, ownerKey: id.ownerName, entryKey: id.tid, in: db) != nil {
                    return .caching
                }
                return .uncached
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to read manga offline cache state for tid \(id.tid): \(error)")
            return .uncached
        }
    }

    func clearAll() async throws {
        do {
            try await database.write { db in
                for table in ReaderDatabaseSchema.offlineCacheTableNamesInDeletionOrder {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            }
            if fileManager.fileExists(atPath: baseDirectory.path) {
                try fileManager.removeItem(at: baseDirectory)
            }
            didRecoverQueueState = true
            notifyOfflineCacheDidChange()
        } catch {
            throw offlineCachePersistenceError(from: error)
        }
    }

    func totalDiskUsageBytes() async -> Int {
        await ensureQueueRecoveredBestEffort()
        do {
            return try await database.read { db in
                let imageBytes = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(byte_count), 0) FROM offline_cache_image_assets"
                ) ?? 0
                let novelBytes = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(byte_count), 0) FROM offline_cache_novel_entries"
                ) ?? 0
                let mangaSourcePageBytes = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(byte_count), 0) FROM offline_cache_manga_entries"
                ) ?? 0
                return imageBytes + novelBytes + mangaSourcePageBytes
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to read total offline cache disk usage: \(error)")
            return 0
        }
    }

    func recoverQueueStateAfterRestart() async throws {
        guard !didRecoverQueueState else { return }
        didRecoverQueueState = true
        do {
            try await database.write { db in
                if try Self.queueRunState(in: db) == .running {
                    try Self.setQueueRunState(.paused, in: db)
                    try Self.pauseRunningOfflineCacheWorks(in: db)
                }
            }
        } catch {
            YamiboLog.offlineCache.error("Failed to recover offline cache queue state after restart: \(error)")
            throw error
        }
    }

    // Every store entry point must run the one-time post-restart queue
    // recovery before touching queue state. The two wrappers below replace the
    // per-method `try`/`try?` prefix boilerplate so that "does this operation
    // tolerate a failed recovery?" is a visible, named decision at each call
    // site instead of a one-character difference. Neither variant retries a
    // failed recovery: `recoverQueueStateAfterRestart()` sets its
    // `didRecoverQueueState` flag before attempting the write, which is the
    // exact behavior every call site already had.
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

    /// Best-effort variant for accessors that have no error channel and must
    /// degrade to an empty/default answer (`nil`, `[]`, `0`, `.paused`)
    /// instead of failing. Swallowing the error here loses no signal:
    /// `recoverQueueStateAfterRestart()` already logs it before rethrowing.
    func ensureQueueRecoveredBestEffort() async {
        try? await recoverQueueStateAfterRestart()
    }

    private func normalizedID(ownerName: String, tid: String) -> MangaOfflineCacheMembershipID? {
        guard let ownerName = ownerName.mangaReaderTrimmedNonEmpty,
              let tid = tid.mangaReaderTrimmedNonEmpty else {
            return nil
        }
        return MangaOfflineCacheMembershipID(ownerName: ownerName, tid: tid)
    }

    func notifyOfflineCacheDidChange() {
        updateNotifier.notify()
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
            YamiboLog.offlineCache.error("Failed to exclude the offline cache directory from backups: \(error)")
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

    private func writeMangaSourcePagePayload(for membership: MangaOfflineCacheMembership) throws -> MangaSourcePagePayload {
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

    private static func normalizedMembership(_ membership: MangaOfflineCacheMembership) throws -> MangaOfflineCacheMembership {
        guard membership.ownerName.mangaReaderTrimmedNonEmpty != nil else {
            throw YamiboPersistenceError(context: "Offline cache owner is empty")
        }
        guard membership.tid.mangaReaderTrimmedNonEmpty != nil else {
            throw YamiboPersistenceError(context: "Chapter tid is empty")
        }
        guard membership.sourcePage.thread.tid == membership.tid else {
            throw YamiboPersistenceError(context: "Manga offline source page does not match chapter tid")
        }
        return MangaOfflineCacheMembership(
            ownerName: membership.ownerName,
            tid: membership.tid,
            chapterTitle: membership.chapterTitle,
            imageURLs: membership.imageURLs,
            sourcePage: membership.sourcePage,
            createdAt: membership.createdAt
        )
    }

    private static func save(
        _ membership: MangaOfflineCacheMembership,
        sourceFileName: String,
        sourceFingerprint: String,
        sourceByteCount: Int,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO offline_cache_manga_entries
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
                offlineCacheTimeInterval(from: membership.createdAt)
            ]
        )
        try db.execute(
            sql: "DELETE FROM offline_cache_manga_entry_images WHERE owner_name = ? AND tid = ?",
            arguments: [membership.ownerName, membership.tid]
        )
        for (index, imageURL) in membership.imageURLs.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO offline_cache_manga_entry_images (owner_name, tid, manual_order, image_url)
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
        in db: Database
    ) throws {
        var desiredByPosition: [Int: String] = [:]
        for (index, imageURL) in imageURLs.enumerated() {
            desiredByPosition[index] = imageURL.absoluteString
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

    static func membership(
        ownerName: String,
        tid: String,
        fileManager: FileManager,
        mangaSourcePagesDirectory: URL,
        sourcePageCache: NSCache<NSString, SourcePageCacheEntry>,
        in db: Database
    ) throws -> MangaOfflineCacheMembership? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT owner_name, tid, chapter_title, source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at
            FROM offline_cache_manga_entries
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
    ) throws -> [MangaOfflineCacheMembership] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT owner_name, tid, chapter_title, source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at
            FROM offline_cache_manga_entries
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
    ) throws -> [MangaOfflineCacheMembership] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT owner_name, tid, chapter_title, source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at
            FROM offline_cache_manga_entries
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
    ) throws -> MangaOfflineCacheMembership? {
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
        return MangaOfflineCacheMembership(
            ownerName: row["owner_name"],
            tid: tid,
            chapterTitle: row["chapter_title"],
            imageURLs: try imageURLs(
                table: "offline_cache_manga_entry_images",
                ownerName: row["owner_name"],
                tid: tid,
                in: db
            ),
            sourcePage: sourcePage,
            createdAt: offlineCacheOptionalDate(from: row["created_at"] as Double?) ?? Date(timeIntervalSince1970: 0)
        )
    }

    static func imageURLs(
        table: String,
        readerKind: String? = nil,
        ownerName: String,
        tid: String,
        in db: Database
    ) throws -> [URL] {
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
        try String.fetchAll(
            db,
            sql: """
            SELECT image_url
            FROM offline_cache_manga_entry_images
            WHERE owner_name = ?
            ORDER BY owner_name ASC, tid ASC, manual_order ASC
            """,
            arguments: [ownerName]
        ).compactMap(URL.init(string:))
    }

    static func mangaEntryByteCount(ownerName: String, tid: String, in db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT byte_count FROM offline_cache_manga_entries WHERE owner_name = ? AND tid = ?",
            arguments: [ownerName, tid]
        ) ?? 0
    }

    private static func deleteMembership(ownerName: String, tid: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM offline_cache_manga_entries WHERE owner_name = ? AND tid = ?",
            arguments: [ownerName, tid]
        )
    }

    static func deleteWork(ownerName: String, tid: String, in db: Database) throws {
        try deleteWork(readerKind: mangaReaderKind, ownerName: ownerName, tid: tid, in: db)
    }

    static func deleteWork(readerKind: String, ownerName: String, tid: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM offline_cache_works WHERE reader_kind = ? AND owner_name = ? AND tid = ?",
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
        guard let fileName = fileName?.mangaReaderTrimmedNonEmpty,
              schemaVersion == 1,
              let fingerprint = fingerprint?.mangaReaderTrimmedNonEmpty,
              let byteCount else {
            return nil
        }
        let fileURL = mangaSourcePagesDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Keying on (tid, fileName, fingerprint, byteCount) means a legitimately replaced
        // source page file (different content -> different fingerprint/byteCount) naturally
        // misses the cache without any explicit invalidation.
        let cacheKey = sourcePageCacheKey(tid: tid, fileName: fileName, fingerprint: fingerprint, byteCount: byteCount) as NSString
        if let cached = sourcePageCache.object(forKey: cacheKey) {
            return cached.sourcePage
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        guard byteCount == data.count,
              sourcePageFingerprint(for: data) == fingerprint else {
            YamiboLog.offlineCache.error("Manga source page file \(fileName) failed fingerprint/byte-count check for tid \(tid); treating cache entry as corrupted")
            return nil
        }
        guard let sourcePage = try? JSONDecoder().decode(ForumThreadPage.self, from: data),
              sourcePage.thread.tid == tid else {
            YamiboLog.offlineCache.error("Failed to decode manga source page file \(fileName) or tid mismatch for tid \(tid)")
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
        let fileNames = try String.fetchAll(
            db,
            sql: """
            SELECT source_page_file_name
            FROM offline_cache_manga_entries
            WHERE owner_name = ? AND tid = ? AND source_page_file_name IS NOT NULL
            """,
            arguments: [ownerName, tid]
        )
        return Set(fileNames.compactMap(\.mangaReaderTrimmedNonEmpty))
    }

    static func mangaSourcePageFileNames(ownerName: String, in db: Database) throws -> Set<String> {
        let fileNames = try String.fetchAll(
            db,
            sql: """
            SELECT source_page_file_name
            FROM offline_cache_manga_entries
            WHERE owner_name = ? AND source_page_file_name IS NOT NULL
            """,
            arguments: [ownerName]
        )
        return Set(fileNames.compactMap(\.mangaReaderTrimmedNonEmpty))
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
            sql: "SELECT source_page_file_name FROM offline_cache_manga_entries WHERE source_page_file_name IS NOT NULL"
        ).compactMap(\.mangaReaderTrimmedNonEmpty))
        for fileName in candidateFileNames where !referenced.contains(fileName) {
            do {
                try fileManager.removeItem(at: mangaSourcePagesDirectory.appendingPathComponent(fileName, isDirectory: false))
            } catch {
                YamiboLog.offlineCache.error("Failed to remove unreferenced manga source page file \(fileName): \(error)")
            }
        }
    }

    /// Global max keeps per-kind enqueue order (a new work sorts after every
    /// existing one) while `offline_cache_works_insertion_idx` answers it in
    /// O(log n) — a per-kind MAX would scan that kind's rows.
    static func nextQueueInsertionIndex(in db: Database) throws -> Int {
        (try Int.fetchOne(
            db,
            sql: "SELECT MAX(insertion_index) FROM offline_cache_works"
        ) ?? 0) + 1
    }

    private static func pauseRunningOfflineCacheWorks(in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE offline_cache_works
            SET state = ?, current_bytes_per_second = 0
            WHERE state = ?
            """,
            arguments: [
                OfflineCacheWorkState.paused.rawValue,
                OfflineCacheWorkState.running.rawValue
            ]
        )
    }

    private static func queueRunState(in db: Database) throws -> OfflineCacheQueueRunState {
        guard let rawValue = try String.fetchOne(
            db,
            sql: "SELECT value FROM offline_cache_queue_state WHERE key = ?",
            arguments: ["run_state"]
        ) else {
            return .paused
        }
        return OfflineCacheQueueRunState(rawValue: rawValue) ?? .paused
    }

    private static func setQueueRunState(_ state: OfflineCacheQueueRunState, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO offline_cache_queue_state (key, value)
            VALUES (?, ?)
            """,
            arguments: ["run_state", state.rawValue]
        )
    }

    private static func defaultBaseDirectory(fileManager: FileManager) -> URL {
        YamiboDatabase.defaultRootDirectory(fileManager: fileManager)
            .appendingPathComponent("offline-cache", isDirectory: true)
    }

}

extension OfflineCacheStore: OfflineCacheStoreCore {}

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

private final class OfflineCacheUpdateNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    func notify() {
        let activeContinuations = lock.withLock {
            Array(continuations.values)
        }
        for continuation in activeContinuations {
            continuation.yield(())
        }
    }

    private func removeContinuation(id: UUID) {
        _ = lock.withLock {
            continuations.removeValue(forKey: id)
        }
    }
}

import Foundation
@preconcurrency import GRDB
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Suite("MangaReaderTests: Manga Offline Cache Persistence")
struct MangaReaderTestsMangaOfflineCachePersistence {
    @Test func appContextDefaultsUseOfflineCacheStore() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-context-offline-cache-defaults-\(UUID().uuidString)", isDirectory: true)
        let appContext = YamiboAppContext(grdbRootDirectory: root, cachesRootDirectory: root)

        #expect(appContext.offlineCacheStore is OfflineCacheStore)
    }

    @Test func membershipWorkAndProgressSurviveRestartWithoutChapterURLColumns() async throws {
        let fixture = try makeOfflineCacheFixture()
        let firstStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURLs = try makeOfflineImageURLs(tid: "100", count: 2)

        try await firstStore.saveMangaOfflineCacheMembership(
            try makeOfflineMembership(ownerName: "作品A", tid: "100", imageURLs: imageURLs)
        )
        _ = try await firstStore.enqueueMangaOfflineCacheWork(
            try makeOfflineWorkRequest(ownerName: "作品A", tid: "101", targetImageURLs: imageURLs)
        )
        try await firstStore.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "101",
            targetImageURLs: imageURLs,
            completedImageURLs: [imageURLs[0]],
            currentBytesPerSecond: 256
        )

        let secondStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let membership = try #require(await secondStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "100"))
        let work = try #require(await secondStore.mangaQueueWork(ownerName: "作品A", tid: "101"))

        #expect(membership.imageURLs == imageURLs)
        #expect(work.completedImageURLs == [imageURLs[0]])
        #expect(work.progress == OfflineCacheProgress(completedUnitCount: 1, targetUnitCount: 2))

        let databaseState = try await fixture.database.read { db in
            (
                membershipColumns: try offlineCacheColumnNames(table: "offline_cache_manga_entries", in: db),
                workColumns: try offlineCacheColumnNames(table: "offline_cache_works", in: db),
                persistedMetadataText: try String.fetchAll(
                    db,
                    sql: """
                    SELECT owner_name FROM offline_cache_manga_entries
                    UNION ALL SELECT tid FROM offline_cache_manga_entries
                    UNION ALL SELECT chapter_title FROM offline_cache_manga_entries
                    UNION ALL SELECT owner_name FROM offline_cache_works
                    UNION ALL SELECT tid FROM offline_cache_works
                    UNION ALL SELECT chapter_title FROM offline_cache_works
                    UNION ALL SELECT state FROM offline_cache_works
                    """
                )
            )
        }

        #expect(!databaseState.membershipColumns.contains("chapter_url"))
        #expect(!databaseState.workColumns.contains("chapter_url"))
        #expect(databaseState.persistedMetadataText.allSatisfy { !$0.contains("forum.php") })
    }

    @Test func recreatedBaseDirectoryStaysExcludedFromBackupAfterClearAll() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURL = try #require(URL(string: "https://img.example.com/backup-exclusion.jpg"))

        try await store.saveOfflineImageData(Data([1]), for: imageURL)
        #expect(try fixture.offlineDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        try await store.clearAll()
        #expect(!FileManager.default.fileExists(atPath: fixture.offlineDirectory.path))

        try await store.saveOfflineImageData(Data([2]), for: imageURL)
        #expect(try fixture.offlineDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func offlineImageBytesStayInFilesWhileMetadataLivesInGRDB() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURL = try #require(URL(string: "https://img.example.com/file-backed.jpg"))

        try await store.saveOfflineImageData(Data([1, 2, 3, 4]), for: imageURL)

        #expect(await store.offlineImageData(for: imageURL) == Data([1, 2, 3, 4]))
        #expect(await store.totalDiskUsageBytes() == 4)

        let imageRows: [(imageURL: String, fileName: String, byteCount: Int)] = try await fixture.database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT image_url, file_name, byte_count FROM offline_cache_image_assets"
            ).map { row in
                (
                    imageURL: row["image_url"] as String,
                    fileName: row["file_name"] as String,
                    byteCount: row["byte_count"] as Int
                )
            }
        }
        let row = try #require(imageRows.first)
        let fileURL = fixture.offlineDirectory
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(row.fileName, isDirectory: false)

        #expect(row.imageURL == imageURL.absoluteString)
        #expect(row.byteCount == 4)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func mangaEntryPersistsAuthorScopedThreadPageSnapshot() async throws {
        let fixture = try makeOfflineCacheFixture()
        let firstStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let sourcePage = try makeOfflineSourcePage(tid: "150")
        let imageURL = try #require(URL(string: "https://img.example.com/150-1.jpg"))

        try await firstStore.saveMangaOfflineCacheMembership(
            MangaOfflineCacheMembership(
                ownerName: "作品A",
                tid: "150",
                chapterTitle: "第150话",
                imageURLs: [imageURL],
                sourcePage: sourcePage
            )
        )

        let secondStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let loaded = try #require(await secondStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "150"))
        let persisted = try #require(try await fixture.database.read { db -> (
            columns: [String],
            fileName: String,
            schemaVersion: Int?,
            fingerprint: String?,
            byteCount: Int
        )? in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count
                FROM offline_cache_manga_entries
                WHERE owner_name = ? AND tid = ?
                """,
                arguments: ["作品A", "150"]
            ) else {
                return nil
            }
            return (
                columns: try offlineCacheColumnNames(table: "offline_cache_manga_entries", in: db),
                fileName: row["source_page_file_name"] as String,
                schemaVersion: row["source_page_schema_version"] as Int?,
                fingerprint: row["source_page_fingerprint"] as String?,
                byteCount: row["byte_count"] as Int
            )
        })
        let sourceFileURL = fixture.offlineDirectory
            .appendingPathComponent("manga-source-pages", isDirectory: true)
            .appendingPathComponent(persisted.fileName, isDirectory: false)
        let sourceData = try Data(contentsOf: sourceFileURL)
        let decodedSourcePage = try JSONDecoder().decode(ForumThreadPage.self, from: sourceData)
        let expectedSourceBytes = try JSONEncoder().encode(sourcePage).count

        #expect(loaded.sourcePage == sourcePage)
        #expect(!persisted.columns.contains("source_page_json"))
        #expect(persisted.schemaVersion == 1)
        #expect(persisted.fingerprint?.isEmpty == false)
        #expect(persisted.byteCount == expectedSourceBytes)
        #expect(decodedSourcePage == sourcePage)
        #expect(await firstStore.totalDiskUsageBytes() == persisted.byteCount)
    }

    @Test func mangaEntryRejectsMismatchedSourcePageThread() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURL = try #require(URL(string: "https://img.example.com/mismatch.jpg"))

        await #expect(throws: YamiboError.self) {
            try await store.saveMangaOfflineCacheMembership(
                MangaOfflineCacheMembership(
                    ownerName: "作品A",
                    tid: "151",
                    chapterTitle: "第151话",
                    imageURLs: [imageURL],
                    sourcePage: try makeOfflineSourcePage(tid: "999")
                )
            )
        }

        #expect(await store.mangaOfflineCacheMembership(ownerName: "作品A", tid: "151") == nil)
    }

    @Test func mangaEntryWithMissingOrDamagedSourceFileIsUnreadableAndUncached() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let membership = try makeOfflineMembership(ownerName: "作品A", tid: "155", imageURLs: [])

        try await store.saveMangaOfflineCacheMembership(membership)
        let fileName = try #require(try await fixture.database.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT source_page_file_name
                FROM offline_cache_manga_entries
                WHERE owner_name = ? AND tid = ?
                """,
                arguments: ["作品A", "155"]
            )
        })
        let sourceFileURL = fixture.offlineDirectory
            .appendingPathComponent("manga-source-pages", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)

        try FileManager.default.removeItem(at: sourceFileURL)

        #expect(await store.mangaOfflineCacheMembership(ownerName: "作品A", tid: "155") == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "作品A", tid: "155") == .uncached)

        try Data("not-json".utf8).write(to: sourceFileURL, options: [.atomic])

        #expect(await store.mangaOfflineCacheMembership(ownerName: "作品A", tid: "155") == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "作品A", tid: "155") == .uncached)

        var tamperedSourcePage = membership.sourcePage
        tamperedSourcePage.title = "第155集"
        let tamperedData = try JSONEncoder().encode(tamperedSourcePage)
        try tamperedData.write(to: sourceFileURL, options: [.atomic])
        try await fixture.database.write { db in
            try db.execute(
                sql: """
                UPDATE offline_cache_manga_entries
                SET byte_count = ?
                WHERE owner_name = ? AND tid = ?
                """,
                arguments: [tamperedData.count, "作品A", "155"]
            )
        }

        #expect(await store.mangaOfflineCacheMembership(ownerName: "作品A", tid: "155") == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "作品A", tid: "155") == .uncached)
    }

    @Test func mangaEntryWithoutSourceFileDoesNotBecomeCachedOrBlockEnqueue() async throws {
        let fixture = try makeOfflineCacheFixture()
        let writingStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURL = try #require(URL(string: "https://img.example.com/legacy-nil-source.jpg"))
        try await writingStore.saveOfflineImageData(Data([9]), for: imageURL)
        try await seedMangaEntryWithoutSourceFile(
            ownerName: "作品A",
            tid: "160",
            imageURLs: [imageURL],
            in: fixture.database
        )

        let recoveredStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )

        #expect(await recoveredStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "160") == nil)
        #expect(await recoveredStore.mangaOfflineCacheState(ownerName: "作品A", tid: "160") == .uncached)
        let result = try await recoveredStore.enqueueMangaOfflineCacheWork(
            try makeOfflineWorkRequest(ownerName: "作品A", tid: "160", targetImageURLs: [imageURL])
        )
        #expect(result.enqueuedWork?.tid == "160")
    }

    @Test func mangaEntryWithoutSourceFileIsExcludedFromCompletedListsUsageAndManagement() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURL = try #require(URL(string: "https://img.example.com/legacy-completed-list.jpg"))
        try await store.saveOfflineImageData(Data([7, 8]), for: imageURL)
        try await seedMangaEntryWithoutSourceFile(
            ownerName: "作品A",
            tid: "165",
            imageURLs: [imageURL],
            in: fixture.database
        )

        #expect(await store.allMangaOfflineCacheMemberships().isEmpty)
        #expect(await store.mangaOfflineCacheMemberships(forOwnerName: "作品A").isEmpty)
        #expect(await store.mangaOfflineCacheDiskUsageByOwner().isEmpty)
        #expect(await store.offlineCacheManagementSnapshot().groups.isEmpty)
        #expect(await store.offlineImageData(for: imageURL) == Data([7, 8]))
    }

    @Test func restartRecoveryDoesNotRepairDeleteInvalidMangaEntriesOrImageBytes() async throws {
        let fixture = try makeOfflineCacheFixture()
        let writingStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let staleImage = try #require(URL(string: "https://img.example.com/stale-only.jpg"))
        let workImage = try #require(URL(string: "https://img.example.com/work-shared.jpg"))
        try await writingStore.saveOfflineImageData(Data([1]), for: staleImage)
        try await writingStore.saveOfflineImageData(Data([2]), for: workImage)
        _ = try await writingStore.enqueueMangaOfflineCacheWork(
            try makeOfflineWorkRequest(ownerName: "作品A", tid: "171", targetImageURLs: [workImage])
        )
        try await seedMangaEntryWithoutSourceFile(
            ownerName: "作品A",
            tid: "170",
            imageURLs: [staleImage, workImage],
            in: fixture.database
        )

        let recoveredStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )

        #expect(await recoveredStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "170") == nil)
        #expect(await recoveredStore.mangaOfflineCacheState(ownerName: "作品A", tid: "170") == .uncached)
        #expect(await recoveredStore.offlineImageData(for: staleImage) == Data([1]))
        #expect(await recoveredStore.offlineImageData(for: workImage) == Data([2]))
        #expect(await recoveredStore.mangaQueueWork(ownerName: "作品A", tid: "171") != nil)
    }

    @Test func restartRecoveryPausesRunningQueueAndKeepsFailedWork() async throws {
        let fixture = try makeOfflineCacheFixture()
        let writingStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURL = try #require(URL(string: "https://img.example.com/restart.jpg"))

        _ = try await writingStore.enqueueMangaOfflineCacheWork(
            try makeOfflineWorkRequest(ownerName: "作品A", tid: "200", targetImageURLs: [imageURL])
        )
        try await writingStore.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "200",
            targetImageURLs: [imageURL],
            completedImageURLs: [imageURL],
            currentBytesPerSecond: 512
        )
        try await writingStore.markOfflineCacheWorkFailed(ownerName: "作品A", tid: "200", message: "Timeout")
        try await writingStore.setOfflineCacheQueueRunState(.running)

        let recoveredStore = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )

        #expect(await recoveredStore.offlineCacheQueueRunState() == .paused)
        let recoveredWork = try #require(await recoveredStore.mangaQueueWork(ownerName: "作品A", tid: "200"))
        #expect(recoveredWork.state == .failed)
        #expect(recoveredWork.failureMessage == "Timeout")
        #expect(recoveredWork.currentBytesPerSecond == 0)
    }

    @Test func progressUpdatesKeepWorkAndImageRowsInPlaceInsteadOfReplacingThem() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURLs = try makeOfflineImageURLs(tid: "500", count: 3)

        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeOfflineWorkRequest(ownerName: "作品A", tid: "500", targetImageURLs: imageURLs)
        )
        try await store.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "500",
            targetImageURLs: nil,
            completedImageURLs: [imageURLs[0]],
            currentBytesPerSecond: 128
        )

        let rowsBefore = try await offlineCacheWorkRowIDs(in: fixture.database)

        try await store.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "500",
            targetImageURLs: nil,
            completedImageURLs: [imageURLs[0], imageURLs[1]],
            currentBytesPerSecond: 256
        )

        let rowsAfter = try await offlineCacheWorkRowIDs(in: fixture.database)
        let work = try #require(await store.mangaQueueWork(ownerName: "作品A", tid: "500"))

        // An INSERT OR REPLACE of the parent row would cascade-delete every image row and
        // re-insert it with a fresh rowid, so stable rowids prove the diffing save path.
        #expect(rowsAfter.work == rowsBefore.work)
        #expect(rowsAfter.targetImages == rowsBefore.targetImages)
        #expect(rowsBefore.targetImages.count == 3)
        #expect(rowsAfter.completedImages[imageURLs[0].absoluteString] == rowsBefore.completedImages[imageURLs[0].absoluteString])
        #expect(rowsAfter.completedImages.count == 2)
        #expect(work.completedImageURLs == [imageURLs[0], imageURLs[1]])
        #expect(work.currentBytesPerSecond == 256)
    }

    @Test func cancelDeleteAndUsageDeriveFromGRDBMetadataPlusFileAvailability() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let sharedImage = try #require(URL(string: "https://img.example.com/shared.jpg"))
        let removedImage = try #require(URL(string: "https://img.example.com/removed.jpg"))

        try await store.saveOfflineImageData(Data([1, 2, 3]), for: sharedImage)
        try await store.saveOfflineImageData(Data([4, 5]), for: removedImage)
        try await store.saveMangaOfflineCacheMembership(
            try makeOfflineMembership(ownerName: "作品A", tid: "300", imageURLs: [sharedImage, removedImage])
        )
        let retainedMembership = try makeOfflineMembership(ownerName: "作品A", tid: "301", imageURLs: [sharedImage])
        try await store.saveMangaOfflineCacheMembership(retainedMembership)

        #expect(await store.mangaOfflineCacheState(ownerName: "作品A", tid: "300") == .cached)

        try await store.removeMangaOfflineCacheMembership(ownerName: "作品A", tid: "300")
        let expectedBytes = try mangaSourcePageByteCount(retainedMembership) + 3

        #expect(await store.mangaOfflineCacheMembership(ownerName: "作品A", tid: "300") == nil)
        #expect(await store.offlineImageData(for: sharedImage) == Data([1, 2, 3]))
        #expect(await store.offlineImageData(for: removedImage) == nil)
        #expect(await store.mangaOfflineCacheDiskUsageByOwner() == [
            MangaOfflineCacheOwnerUsage(ownerName: "作品A", byteCount: expectedBytes)
        ])
    }

    @Test func removingMangaMembershipOrOwnerDeletesUnreferencedSourcePageFiles() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let firstMembership = try makeOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [])
        let secondMembership = try makeOfflineMembership(ownerName: "作品A", tid: "311", imageURLs: [])

        try await store.saveMangaOfflineCacheMembership(firstMembership)
        try await store.saveMangaOfflineCacheMembership(secondMembership)
        let fileNames = try await mangaSourcePageFileNames(
            ownerName: "作品A",
            tids: ["310", "311"],
            in: fixture.database
        )
        let firstFileURL = fixture.offlineDirectory
            .appendingPathComponent("manga-source-pages", isDirectory: true)
            .appendingPathComponent(try #require(fileNames["310"]), isDirectory: false)
        let secondFileURL = fixture.offlineDirectory
            .appendingPathComponent("manga-source-pages", isDirectory: true)
            .appendingPathComponent(try #require(fileNames["311"]), isDirectory: false)

        try await store.removeMangaOfflineCacheMembership(ownerName: "作品A", tid: "310")

        #expect(!FileManager.default.fileExists(atPath: firstFileURL.path))
        #expect(FileManager.default.fileExists(atPath: secondFileURL.path))

        try await store.removeMangaOfflineCacheMemberships(forOwnerName: "作品A")

        #expect(!FileManager.default.fileExists(atPath: secondFileURL.path))
    }

    @Test func queueExecutorProcessesGRDBBackedWorkAndRemovesCompletedQueueRows() async throws {
        let fixture = try makeOfflineCacheFixture()
        let store = OfflineCacheStore(
            databasePool: fixture.database,
            baseDirectory: fixture.offlineDirectory
        )
        let imageURLs = try makeOfflineImageURLs(tid: "400", count: 2)
        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeOfflineWorkRequest(ownerName: "作品A", tid: "400", targetImageURLs: imageURLs)
        )
        let acquirer = RecordingOfflineImageAcquirer()
        await acquirer.setData(for: imageURLs)
        let executor = OfflineCacheQueueExecutor(
            store: store,
            mangaCacheStore: store,
            novelCacheStore: store,
            readerProjectionLoader: RecordingReaderProjectionLoader(documents: [
                try makeDocument(tid: "400", imageURLs: imageURLs)
            ]),
            imageAcquirer: acquirer,
            maxConcurrentImageTransfers: 1
        )

        try await executor.continueQueue()
        await executor.waitForIdle()

        #expect(await store.mangaQueueWork(ownerName: "作品A", tid: "400") == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "作品A", tid: "400") == .cached)
        #expect(await store.mangaOfflineCacheMembership(ownerName: "作品A", tid: "400")?.imageURLs == imageURLs)
        #expect(await acquirer.requestedURLs == imageURLs)
    }
}

private struct OfflineCacheFixture {
    let database: DatabasePool
    let offlineDirectory: URL
}

private func makeOfflineCacheFixture() throws -> OfflineCacheFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("grdb-offline-cache-\(UUID().uuidString)", isDirectory: true)
    return OfflineCacheFixture(
        database: try YamiboDatabase.openPool(rootDirectory: root),
        offlineDirectory: root.appendingPathComponent("offline-images", isDirectory: true)
    )
}

private func makeOfflineMembership(
    ownerName: String,
    tid: String,
    imageURLs: [URL]
) throws -> MangaOfflineCacheMembership {
    MangaOfflineCacheMembership(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs,
        sourcePage: try makeOfflineSourcePage(tid: tid)
    )
}

private func makeOfflineWorkRequest(
    ownerName: String,
    tid: String,
    targetImageURLs: [URL]
) throws -> MangaOfflineCacheWorkRequest {
    MangaOfflineCacheWorkRequest(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        targetImageURLs: targetImageURLs
    )
}

private func makeOfflineImageURLs(tid: String, count: Int) throws -> [URL] {
    try (1...count).map { index in
        try #require(URL(string: "https://img.example.com/\(tid)-\(index).jpg"))
    }
}

private func makeDocument(tid: String, imageURLs: [URL]) throws -> MangaReaderProjection {
    MangaReaderProjection(
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs
    )
}

private func makeOfflineSourcePage(tid: String) throws -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "第\(tid)话",
        posts: [
            ForumThreadPost(
                postID: "p-\(tid)",
                author: BlogReaderUser(uid: "author-\(tid)", name: "作者"),
                contentHTML: #"<img src="https://img.example.com/\#(tid)-1.jpg">"#,
                contentText: "",
                images: [
                    ForumThreadPostImage(url: "https://img.example.com/\(tid)-1.jpg")
                ]
            )
        ]
    )
}

private func mangaSourcePageByteCount(_ membership: MangaOfflineCacheMembership) throws -> Int {
    try JSONEncoder().encode(membership.sourcePage).count
}

private func mangaSourcePageFileNames(
    ownerName: String,
    tids: [String],
    in database: DatabasePool
) async throws -> [String: String] {
    try await database.read { db in
        var fileNames: [String: String] = [:]
        for tid in tids {
            fileNames[tid] = try String.fetchOne(
                db,
                sql: """
                SELECT source_page_file_name
                FROM offline_cache_manga_entries
                WHERE owner_name = ? AND tid = ?
                """,
                arguments: [ownerName, tid]
            )
        }
        return fileNames
    }
}

private func seedMangaEntryWithoutSourceFile(
    ownerName: String,
    tid: String,
    imageURLs: [URL],
    in database: DatabasePool
) async throws {
    try await database.write { db in
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO offline_cache_manga_entries
            (owner_name, tid, chapter_title, source_page_file_name, source_page_schema_version, source_page_fingerprint, byte_count, created_at)
            VALUES (?, ?, ?, NULL, NULL, NULL, 0, ?)
            """,
            arguments: [
                ownerName,
                tid,
                "第\(tid)话",
                Date().timeIntervalSince1970
            ]
        )
        try db.execute(
            sql: "DELETE FROM offline_cache_manga_entry_images WHERE owner_name = ? AND tid = ?",
            arguments: [ownerName, tid]
        )
        for (index, imageURL) in imageURLs.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO offline_cache_manga_entry_images
                (owner_name, tid, manual_order, image_url)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [ownerName, tid, index, imageURL.absoluteString]
            )
        }
    }
}

private func offlineCacheColumnNames(table: String, in db: Database) throws -> [String] {
    try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
}

private struct OfflineCacheWorkRowIDs {
    var work: Int64?
    var targetImages: [String: Int64]
    var completedImages: [String: Int64]
}

private func offlineCacheWorkRowIDs(in database: DatabasePool) async throws -> OfflineCacheWorkRowIDs {
    try await database.read { db in
        let work = try Int64.fetchOne(db, sql: "SELECT rowid FROM offline_cache_works")
        var targetImages: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT rowid, image_url FROM offline_cache_work_images") {
            targetImages[row["image_url"] as String] = row["rowid"] as Int64
        }
        var completedImages: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT rowid, image_url FROM offline_cache_completed_images") {
            completedImages[row["image_url"] as String] = row["rowid"] as Int64
        }
        return OfflineCacheWorkRowIDs(
            work: work,
            targetImages: targetImages,
            completedImages: completedImages
        )
    }
}

private actor RecordingOfflineImageAcquirer: OfflineCacheImageAcquiring {
    private(set) var requestedURLs: [URL] = []
    private var dataByURL: [URL: Data] = [:]

    func setData(for imageURLs: [URL]) {
        for (index, imageURL) in imageURLs.enumerated() {
            dataByURL[imageURL] = Data([UInt8(index + 1)])
        }
    }

    func acquireImageData(for source: YamiboImageSource) async throws -> OfflineCacheImageAcquisition {
        requestedURLs.append(source.url)
        guard let data = dataByURL[source.url] else {
            throw YamiboError.invalidResponse(statusCode: 404)
        }
        return OfflineCacheImageAcquisition(data: data, source: .network)
    }
}

private actor RecordingReaderProjectionLoader: MangaReaderProjectionSnapshotLoading {
    private let documentsByTID: [String: MangaReaderProjection]

    init(documents: [MangaReaderProjection] = []) {
        self.documentsByTID = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        try await loadReaderProjectionSnapshot(request).projection
    }

    func loadReaderProjectionSnapshot(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjectionSnapshot {
        guard let projection = documentsByTID[request.threadID] else {
            throw YamiboError.parsingFailed(context: "Unexpected document load in offline-cache test")
        }
        return MangaReaderProjectionSnapshot(
            projection: projection,
            sourcePage: try makeOfflineSourcePage(tid: projection.tid)
        )
    }
}

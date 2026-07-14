import XCTest
import GRDB
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class MangaReaderCacheViewModelTests: XCTestCase {
    func testProjectsDirectoryChaptersInPanelOrderWithCachedUncachedAndCachingStates() async throws {
        let fixture = try await makeCacheFixture(chapters: [
            cacheChapter(tid: "100", number: 1),
            cacheChapter(tid: "200", number: 2),
            cacheChapter(tid: "300", number: 3)
        ])
        let cachedImage = try XCTUnwrap(URL(string: "https://img.example.com/100-1.jpg"))

        try await fixture.store.saveOfflineImageData(Data([1]), for: cachedImage)
        try await fixture.store.saveMangaOfflineCacheMembership(cacheMembership(favorite: fixture.favorite, tid: "100", imageURLs: [cachedImage]))
        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "300"))

        await fixture.model.load()

        XCTAssertEqual(fixture.model.rows.map(\.chapter.tid), ["100", "200", "300"])
        XCTAssertEqual(fixture.model.rows.map(\.state), [.cached, .uncached, .caching])
    }

    func testLoadProjectsExistingOfflineCacheQueueEntryCount() async throws {
        let fixture = try await makeCacheFixture(chapters: [
            cacheChapter(tid: "100", number: 1),
            cacheChapter(tid: "200", number: 2)
        ])
        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "100"))
        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "200"))

        await fixture.model.load()

        XCTAssertEqual(fixture.model.offlineCacheQueueEntryCount, 2)
    }

    func testOfflineCacheQueueUpdatesRefreshEntryCountAndRows() async throws {
        let fixture = try await makeCacheFixture(chapters: [cacheChapter(tid: "100", number: 1)])

        await fixture.model.load()
        XCTAssertEqual(fixture.model.offlineCacheQueueEntryCount, 0)
        XCTAssertEqual(fixture.model.rows.map(\.state), [.uncached])

        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "100"))

        try await waitForMangaReaderCacheCondition {
            fixture.model.offlineCacheQueueEntryCount == 1
                && fixture.model.rows.map(\.state) == [.caching]
        }

        try await fixture.store.cancelOfflineCacheEntry(OfflineCacheEntryID(
            readerKind: .manga,
            ownerKey: fixture.favorite.title,
            entryKey: "100"
        ))

        try await waitForMangaReaderCacheCondition {
            fixture.model.offlineCacheQueueEntryCount == 0
                && fixture.model.rows.map(\.state) == [.uncached]
        }
    }

    func testFailedQueueWorkProjectsAsCaching() async throws {
        let fixture = try await makeCacheFixture(chapters: [cacheChapter(tid: "100", number: 1)])
        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "100"))
        try await fixture.store.markOfflineCacheWorkFailed(ownerName: fixture.favorite.title, tid: "100", message: "Timeout")

        await fixture.model.load()

        XCTAssertEqual(fixture.model.rows.map(\.state), [.caching])
    }

    func testCacheCommandEnqueuesOnlyUncachedChaptersAndDoesNotRetryFailedWork() async throws {
        let fixture = try await makeCacheFixture(chapters: [
            cacheChapter(tid: "100", number: 1),
            cacheChapter(tid: "200", number: 2),
            cacheChapter(tid: "300", number: 3)
        ])
        let cachedImage = try XCTUnwrap(URL(string: "https://img.example.com/100-1.jpg"))
        try await fixture.store.saveOfflineImageData(Data([1]), for: cachedImage)
        try await fixture.store.saveMangaOfflineCacheMembership(cacheMembership(favorite: fixture.favorite, tid: "100", imageURLs: [cachedImage]))
        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "300"))
        try await fixture.store.markOfflineCacheWorkFailed(ownerName: fixture.favorite.title, tid: "300", message: "Timeout")

        await fixture.model.load()
        await fixture.model.cacheSelected(tids: ["100", "200", "300"])

        let works = await fixture.store.mangaQueueWorks()
        XCTAssertEqual(Set(works.map(\.tid)), ["200", "300"])
        XCTAssertEqual(works.first(where: { $0.tid == "300" })?.state, .failed)
        XCTAssertEqual(fixture.model.rows.map(\.state), [.cached, .caching, .caching])
    }

    func testCacheEntryWithoutSourceFileProjectsUncachedAndCanBeEnqueued() async throws {
        let controller = RecordingMangaReaderCacheQueueController()
        let fixture = try await makeCacheFixture(
            chapters: [cacheChapter(tid: "100", number: 1)],
            offlineCacheQueueControllerProvider: { controller }
        )
        let legacyImage = try XCTUnwrap(URL(string: "https://img.example.com/legacy-100-1.jpg"))
        try await fixture.store.saveOfflineImageData(Data([1]), for: legacyImage)
        try await seedMangaCacheEntryWithoutSourceFile(
            ownerName: fixture.favorite.title,
            tid: "100",
            imageURLs: [legacyImage],
            in: fixture.database
        )

        await fixture.model.load()
        XCTAssertEqual(fixture.model.rows.map(\.state), [.uncached])

        await fixture.model.cacheSelected(tids: ["100"])

        let works = await fixture.store.mangaQueueWorks()
        XCTAssertEqual(works.map(\.tid), ["100"])
        XCTAssertEqual(fixture.model.rows.map(\.state), [.caching])
        let events = await controller.snapshotEvents()
        XCTAssertEqual(events, ["continue"])
    }

    func testCacheCommandStartsOfflineCacheQueueAfterEnqueuingNewChapters() async throws {
        let controller = RecordingMangaReaderCacheQueueController()
        let fixture = try await makeCacheFixture(
            chapters: [cacheChapter(tid: "100", number: 1)],
            offlineCacheQueueControllerProvider: { controller }
        )

        await fixture.model.load()
        await fixture.model.cacheSelected(tids: ["100"])

        let events = await controller.snapshotEvents()
        XCTAssertEqual(events, ["continue"])
    }

    func testCacheCommandDoesNotContinueQueueWhenFailedWorkIsPresent() async throws {
        let controller = RecordingMangaReaderCacheQueueController()
        let fixture = try await makeCacheFixture(
            chapters: [
                cacheChapter(tid: "100", number: 1),
                cacheChapter(tid: "200", number: 2)
            ],
            offlineCacheQueueControllerProvider: { controller }
        )
        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "200"))
        try await fixture.store.markOfflineCacheWorkFailed(ownerName: fixture.favorite.title, tid: "200", message: "Timeout")

        await fixture.model.load()
        await fixture.model.cacheSelected(tids: ["100", "200"])

        let events = await controller.snapshotEvents()
        XCTAssertEqual(events, [])
        let works = await fixture.store.mangaQueueWorks()
        XCTAssertEqual(Set(works.map(\.tid)), ["100", "200"])
        XCTAssertEqual(works.first(where: { $0.tid == "200" })?.state, .failed)
    }

    func testDeleteCommandRemovesCachedMembershipAndCancelsUnfinishedOrFailedWork() async throws {
        let fixture = try await makeCacheFixture(chapters: [
            cacheChapter(tid: "100", number: 1),
            cacheChapter(tid: "200", number: 2),
            cacheChapter(tid: "300", number: 3)
        ])
        let cachedImage = try XCTUnwrap(URL(string: "https://img.example.com/100-1.jpg"))
        try await fixture.store.saveOfflineImageData(Data([1]), for: cachedImage)
        try await fixture.store.saveMangaOfflineCacheMembership(cacheMembership(favorite: fixture.favorite, tid: "100", imageURLs: [cachedImage]))
        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "200"))
        _ = try await fixture.store.enqueueMangaOfflineCacheWork(cacheWorkRequest(favorite: fixture.favorite, tid: "300"))
        try await fixture.store.markOfflineCacheWorkFailed(ownerName: fixture.favorite.title, tid: "300", message: "Timeout")

        await fixture.model.load()
        await fixture.model.deleteSelected(tids: ["100", "200", "300"])

        let deletedMembership = await fixture.store.mangaOfflineCacheMembership(ownerName: fixture.favorite.title, tid: "100")
        let deletedImageData = await fixture.store.offlineImageData(for: cachedImage)
        let remainingWorks = await fixture.store.mangaQueueWorks()
        XCTAssertNil(deletedMembership)
        XCTAssertNil(deletedImageData)
        XCTAssertTrue(remainingWorks.isEmpty)
        XCTAssertEqual(fixture.model.rows.map(\.state), [.uncached, .uncached, .uncached])
    }

    func testNonFavoriteCacheCommandEnqueuesWorkWithoutPrompting() async throws {
        let fixture = try await makeCacheFixture(chapters: [cacheChapter(tid: "100", number: 1)], saveFavorite: false)

        await fixture.model.load()
        await fixture.model.cacheSelected(tids: ["100"])

        XCTAssertNil(fixture.model.prompt)
        let works = await fixture.store.mangaQueueWorks()
        XCTAssertEqual(works.map(\.ownerName), ["测试漫画"])
        XCTAssertEqual(works.map(\.tid), ["100"])
        XCTAssertEqual(fixture.model.rows.map(\.state), [.caching])
    }

    func testNonFavoriteDeleteCommandCanRemoveExistingOfflineCache() async throws {
        let fixture = try await makeCacheFixture(chapters: [cacheChapter(tid: "100", number: 1)], saveFavorite: false)
        let cachedImage = try XCTUnwrap(URL(string: "https://img.example.com/nonfavorite-100-1.jpg"))
        try await fixture.store.saveOfflineImageData(Data([1]), for: cachedImage)
        try await fixture.store.saveMangaOfflineCacheMembership(cacheMembership(favorite: fixture.favorite, tid: "100", imageURLs: [cachedImage]))

        await fixture.model.load()
        XCTAssertEqual(fixture.model.rows.map(\.state), [.cached])

        await fixture.model.deleteSelected(tids: ["100"])

        let deletedMembership = await fixture.store.mangaOfflineCacheMembership(ownerName: fixture.favorite.title, tid: "100")
        let deletedImageData = await fixture.store.offlineImageData(for: cachedImage)
        XCTAssertNil(deletedMembership)
        XCTAssertNil(deletedImageData)
        XCTAssertEqual(fixture.model.rows.map(\.state), [.uncached])
    }
}

private struct MangaReaderCacheFixture {
    let model: MangaReaderCacheViewModel
    let favorite: Favorite
    let store: OfflineCacheStore
    let database: DatabasePool
}

@MainActor
private func makeCacheFixture(
    chapters: [MangaChapter],
    saveFavorite: Bool = true,
    offlineCacheQueueControllerProvider: (@Sendable () async -> any OfflineCacheQueueControlling)? = nil
) async throws -> MangaReaderCacheFixture {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "manga-reader-cache")
    let localFavoriteLibraryStore = FavoriteLibraryStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
        key: "favorite-library"
    )
    let offlineRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("manga-reader-cache-grdb-\(UUID().uuidString)", isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: offlineRoot)
    let offlineStore = OfflineCacheStore(
        databasePool: database,
        baseDirectory: offlineRoot.appendingPathComponent("offline-images", isDirectory: true)
    )
    let favorite = Favorite(
        id: "favorite-900",
        title: "测试漫画",
        threadID: "900",
        type: .manga
    )
    if saveFavorite {
        var document = FavoriteLibraryDocument()
        // `MangaReaderCacheModule.localFavoriteItem()` now matches purely by
        // `item.target.threadID == context.originalThreadID` (smart-comic-mode
        // Phase A decision #3/#9 — there is no cleanBookName-keyed identity
        // left to look up by directory title), so the seeded favorite must be
        // `.mangaThread`-targeted at the launch context's own thread id.
        document.upsertItem(try FavoriteItem(
            target: .mangaThread(threadID: "900"),
            title: "测试漫画",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
    }

    let panel = MangaDirectoryPanelPresentation(
        directoryTitle: "测试漫画",
        displayChapters: chapters,
        sortOrder: .ascending
    )
    let context = MangaLaunchContext(
        originalThreadID: "900",
        chapterTID: chapters[0].tid,
        displayTitle: "测试漫画",
        source: .forum,
        directoryName: "测试漫画"
    )
    return MangaReaderCacheFixture(
        model: MangaReaderCacheViewModel(
            context: context,
            panel: panel,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            offlineCacheStore: offlineStore,
            offlineCacheQueueControllerProvider: offlineCacheQueueControllerProvider
        ),
        favorite: favorite,
        store: offlineStore,
        database: database
    )
}

private actor RecordingMangaReaderCacheQueueController: OfflineCacheQueueControlling {
    private var events: [String] = []

    func snapshotEvents() -> [String] {
        events
    }

    func continueQueue() async throws {
        events.append("continue")
    }

    func pauseQueue() async throws {
        events.append("pause")
    }

    func cancelChapter(ownerName: String, tid: String) async throws {
        events.append("cancel:\(ownerName):\(tid)")
    }

    func cancelOwnerGroup(ownerName: String) async throws {
        events.append("cancel-group:\(ownerName)")
    }
}

private func cacheChapter(tid: String, number: Double) throws -> MangaChapter {
    MangaChapter(
        tid: tid,
        rawTitle: "第\(Int(number))话",
        chapterNumber: number
    )
}

private func cacheMembership(
    favorite: Favorite,
    tid: String,
    imageURLs: [URL]
) throws -> MangaOfflineCacheMembership {
    MangaOfflineCacheMembership(
        ownerName: favorite.title,
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs,
        sourcePage: makeCacheSourcePage(tid: tid)
    )
}

private func makeCacheSourcePage(tid: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "第\(tid)话",
        posts: [
            ForumThreadPost(
                postID: "p-\(tid)",
                author: BlogReaderUser(uid: "author-\(tid)", name: "作者"),
                contentHTML: "",
                contentText: ""
            )
        ]
    )
}

private func seedMangaCacheEntryWithoutSourceFile(
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

private func cacheWorkRequest(favorite: Favorite, tid: String) throws -> MangaOfflineCacheWorkRequest {
    MangaOfflineCacheWorkRequest(
        ownerName: favorite.title,
        tid: tid,
        chapterTitle: "第\(tid)话"
    )
}

private func waitForMangaReaderCacheCondition(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let start = ContinuousClock.now
    while await MainActor.run(body: condition) == false {
        if start.duration(to: .now) > .nanoseconds(Int64(timeoutNanoseconds)) {
            throw YamiboError.underlying("Timed out waiting for condition")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

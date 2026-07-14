import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Suite("MangaReaderTests: Manga Offline Cache Queue")
struct MangaReaderTestsMangaOfflineCacheQueue {
    @Test func enqueuePersistsQueueWorkWithOwnerMetadataAndInsertionOrder() async throws {
        let directory = try makeTemporaryOfflineCacheQueueDirectory()
        let firstStore = try makeTestOfflineCacheStore(rootDirectory: directory)

        let result = try await firstStore.enqueueMangaOfflineCacheWork(
            makeOfflineCacheWorkRequest(
                ownerName: " favorite-a ",
                tid: " 100 ",
                targetImageURLs: [
                    try #require(URL(string: "https://img.example.com/100-1.jpg")),
                    try #require(URL(string: "https://img.example.com/100-2.jpg"))
                ]
            )
        )

        let enqueued = try #require(result.enqueuedWork)
        #expect(enqueued.ownerName == "favorite-a")
        #expect(enqueued.tid == "100")
        #expect(enqueued.insertionIndex == 1)
        #expect(enqueued.state == .queued)

        let secondStore = try makeTestOfflineCacheStore(rootDirectory: directory)
        #expect(await secondStore.mangaQueueWorkProjections() == [enqueued])
    }

    @Test func enqueueIsIdempotentForExistingQueueWorkAndCachedMembership() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryOfflineCacheQueueDirectory())
        let firstRequest = try makeOfflineCacheWorkRequest(ownerName: "favorite-a", tid: "100")
        let secondRequest = try makeOfflineCacheWorkRequest(
            ownerName: "favorite-a",
            tid: "200",
            targetImageURLs: [try #require(URL(string: "https://img.example.com/cached.jpg"))]
        )

        let firstResult = try await store.enqueueMangaOfflineCacheWork(firstRequest)
        let secondResult = try await store.enqueueMangaOfflineCacheWork(firstRequest)

        let firstWork = try #require(firstResult.enqueuedWork)
        #expect(secondResult == .alreadyQueued(firstWork))
        #expect(await store.mangaQueueWorkProjections() == [firstWork])

        let cachedMembership = try makeOfflineCacheMembership(ownerName: "favorite-a", tid: "200", imageURLs: secondRequest.targetImageURLs)
        try await store.saveOfflineImageData(Data([1, 2, 3]), for: secondRequest.targetImageURLs[0])
        try await store.saveMangaOfflineCacheMembership(cachedMembership)

        let cachedResult = try await store.enqueueMangaOfflineCacheWork(secondRequest)

        guard case let .alreadyCached(loadedMembership) = cachedResult else {
            Issue.record("Expected existing cached membership")
            return
        }
        #expect(loadedMembership.id == cachedMembership.id)
        #expect(loadedMembership.chapterTitle == cachedMembership.chapterTitle)
        #expect(loadedMembership.imageURLs == cachedMembership.imageURLs)
        #expect(await store.mangaQueueWorkProjections() == [firstWork])
    }

    @Test func failedQueueWorkPersistsUntilCanceledAndProjectsAsCaching() async throws {
        let directory = try makeTemporaryOfflineCacheQueueDirectory()
        let writingStore = try makeTestOfflineCacheStore(rootDirectory: directory)
        let request = try makeOfflineCacheWorkRequest(ownerName: "favorite-a", tid: "100")

        _ = try await writingStore.enqueueMangaOfflineCacheWork(request)
        try await writingStore.markOfflineCacheWorkFailed(
            ownerName: "favorite-a",
            tid: "100",
            message: "Network unavailable"
        )

        let readingStore = try makeTestOfflineCacheStore(rootDirectory: directory)
        let failedWork = try #require(await readingStore.mangaQueueWork(ownerName: "favorite-a", tid: "100"))

        #expect(failedWork.state == .failed)
        #expect(failedWork.failureMessage == "Network unavailable")
        #expect(await readingStore.mangaOfflineCacheState(ownerName: "favorite-a", tid: "100") == .caching)

        try await readingStore.cancelOfflineCacheEntry(OfflineCacheEntryID(
            readerKind: .manga,
            ownerKey: "favorite-a",
            entryKey: "100"
        ))

        #expect(await readingStore.mangaQueueWork(ownerName: "favorite-a", tid: "100") == nil)
        #expect(await readingStore.mangaOfflineCacheState(ownerName: "favorite-a", tid: "100") == .uncached)
    }

    @Test func progressSnapshotsPersistAcrossStoreInstances() async throws {
        let directory = try makeTemporaryOfflineCacheQueueDirectory()
        let writingStore = try makeTestOfflineCacheStore(rootDirectory: directory)
        let firstImage = try #require(URL(string: "https://img.example.com/100-1.jpg"))
        let secondImage = try #require(URL(string: "https://img.example.com/100-2.jpg"))
        let thirdImage = try #require(URL(string: "https://img.example.com/100-3.jpg"))

        _ = try await writingStore.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(
                ownerName: "favorite-a",
                tid: "100",
                targetImageURLs: [firstImage]
            )
        )
        try await writingStore.updateOfflineCacheWorkProgress(
            ownerName: "favorite-a",
            tid: "100",
            targetImageURLs: [firstImage, secondImage, thirdImage],
            completedImageURLs: [firstImage, secondImage],
            currentBytesPerSecond: nil
        )

        let readingStore = try makeTestOfflineCacheStore(rootDirectory: directory)
        let work = try #require(await readingStore.mangaQueueWork(ownerName: "favorite-a", tid: "100"))

        #expect(work.targetImageURLs == [firstImage, secondImage, thirdImage])
        #expect(work.completedImageURLs == [firstImage, secondImage])
        #expect(work.progress == OfflineCacheProgress(completedUnitCount: 2, targetUnitCount: 3))
    }

    @Test func membershipDeletionCancelsQueueWorkEvenWithoutCachedImages() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryOfflineCacheQueueDirectory())
        let imageURL = try #require(URL(string: "https://img.example.com/100-1.jpg"))

        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "favorite-a", tid: "100", targetImageURLs: [imageURL])
        )
        try await store.saveMangaOfflineCacheMembership(
            try makeOfflineCacheMembership(ownerName: "favorite-a", tid: "100", imageURLs: [imageURL])
        )

        try await store.removeMangaOfflineCacheMembership(ownerName: "favorite-a", tid: "100")

        #expect(await store.mangaQueueWork(ownerName: "favorite-a", tid: "100") == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "100") == .uncached)
    }

    @Test func membershipDeletionRemovesPartialOfflineBytesForCanceledQueueWork() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryOfflineCacheQueueDirectory())
        let imageURL = try #require(URL(string: "https://img.example.com/100-1.jpg"))

        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(ownerName: "favorite-a", tid: "100", targetImageURLs: [imageURL])
        )
        try await store.saveOfflineImageData(Data([1]), for: imageURL)
        try await store.updateOfflineCacheWorkProgress(
            ownerName: "favorite-a",
            tid: "100",
            targetImageURLs: [imageURL],
            completedImageURLs: [imageURL],
            currentBytesPerSecond: nil
        )

        try await store.removeMangaOfflineCacheMembership(ownerName: "favorite-a", tid: "100")

        #expect(await store.mangaQueueWork(ownerName: "favorite-a", tid: "100") == nil)
        #expect(await store.offlineImageData(for: imageURL) == nil)
    }

    @Test func completedMembershipLeavesQueueWhenAllOfflineImagesArePresent() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryOfflineCacheQueueDirectory())
        let firstImage = try #require(URL(string: "https://img.example.com/100-1.jpg"))
        let secondImage = try #require(URL(string: "https://img.example.com/100-2.jpg"))

        _ = try await store.enqueueMangaOfflineCacheWork(
            try makeOfflineCacheWorkRequest(
                ownerName: "favorite-a",
                tid: "100",
                targetImageURLs: [firstImage, secondImage]
            )
        )
        try await store.saveMangaOfflineCacheMembership(
            try makeOfflineCacheMembership(
                ownerName: "favorite-a",
                tid: "100",
                imageURLs: [firstImage, secondImage]
            )
        )
        try await store.saveOfflineImageData(Data([1]), for: firstImage)

        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "100") == .caching)

        try await store.saveOfflineImageData(Data([2]), for: secondImage)

        #expect(await store.mangaQueueWork(ownerName: "favorite-a", tid: "100") == nil)
        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "100") == .cached)
    }

    @Test func queueProjectionGroupsByOwnerAndOrdersChaptersByDirectoryWhenAvailable() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryOfflineCacheQueueDirectory())
        _ = try await store.enqueueMangaOfflineCacheWork(try makeOfflineCacheWorkRequest(ownerName: "作品B", tid: "300"))
        _ = try await store.enqueueMangaOfflineCacheWork(try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "200"))
        _ = try await store.enqueueMangaOfflineCacheWork(try makeOfflineCacheWorkRequest(ownerName: "作品A", tid: "100"))

        let works = await store.mangaQueueWorks()

        #expect(works.count == 3)
        #expect(works.map(\.ownerName) == ["作品B", "作品A", "作品A"])
        #expect(works.map(\.tid) == ["300", "200", "100"])
    }

    @Test func restartRecoveryPausesRunningQueueWithoutDroppingFailedWork() async throws {
        let directory = try makeTemporaryOfflineCacheQueueDirectory()
        let writingStore = try makeTestOfflineCacheStore(rootDirectory: directory)

        _ = try await writingStore.enqueueMangaOfflineCacheWork(try makeOfflineCacheWorkRequest(ownerName: "favorite-a", tid: "100"))
        _ = try await writingStore.enqueueMangaOfflineCacheWork(try makeOfflineCacheWorkRequest(ownerName: "favorite-a", tid: "200"))
        try await writingStore.markOfflineCacheWorkFailed(ownerName: "favorite-a", tid: "200", message: "Timeout")
        try await writingStore.prepareOfflineCacheWorkForRun(
            ownerName: "favorite-a",
            tid: "100",
            targetImageURLs: nil,
            completedImageURLs: []
        )
        try await writingStore.setOfflineCacheQueueRunState(.running)

        let readingStore = try makeTestOfflineCacheStore(rootDirectory: directory)

        #expect(await readingStore.offlineCacheQueueRunState() == .paused)
        #expect(await readingStore.mangaQueueWork(ownerName: "favorite-a", tid: "100")?.state == .paused)
        #expect(await readingStore.mangaQueueWork(ownerName: "favorite-a", tid: "200")?.state == .failed)
    }

    @Test func readerFacingCacheStateRequiresMembershipAndAllOfflineImages() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryOfflineCacheQueueDirectory())
        let firstImage = try #require(URL(string: "https://img.example.com/100-1.jpg"))
        let secondImage = try #require(URL(string: "https://img.example.com/100-2.jpg"))

        try await store.saveMangaOfflineCacheMembership(
            try makeOfflineCacheMembership(
                ownerName: "favorite-a",
                tid: "100",
                imageURLs: [firstImage, secondImage]
            )
        )
        try await store.saveOfflineImageData(Data([1]), for: firstImage)

        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "100") == .uncached)

        try await store.saveOfflineImageData(Data([2]), for: secondImage)

        #expect(await store.mangaOfflineCacheState(ownerName: "favorite-a", tid: "100") == .cached)
    }
}

private func makeOfflineCacheWorkRequest(
    ownerName: String,
    tid: String,
    targetImageURLs: [URL] = []
) throws -> MangaOfflineCacheWorkRequest {
    MangaOfflineCacheWorkRequest(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        targetImageURLs: targetImageURLs
    )
}

private func makeOfflineCacheMembership(
    ownerName: String,
    tid: String,
    imageURLs: [URL]
) throws -> MangaOfflineCacheMembership {
    MangaOfflineCacheMembership(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs,
        sourcePage: makeTestMangaOfflineSourcePage(tid: tid)
    )
}

private func makeTestMangaOfflineSourcePage(tid: String) -> ForumThreadPage {
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

private func makeDirectoryChapter(tid: String, chapterNumber: Double) throws -> MangaChapter {
    MangaChapter(
        tid: tid,
        rawTitle: "第\(tid)话",
        chapterNumber: chapterNumber
    )
}

private func makeTemporaryOfflineCacheQueueDirectory() throws -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

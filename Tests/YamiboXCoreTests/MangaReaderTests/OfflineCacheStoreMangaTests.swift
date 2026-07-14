import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Suite("MangaReaderTests: Manga Offline Cache Store")
struct MangaReaderTestsOfflineCacheStore {
    @Test func savesMembershipWithOwnerAndChapterIdentityAcrossStoreInstances() async throws {
        let directory = try makeTemporaryOfflineCacheDirectory()
        let imageURL = try #require(URL(string: "https://img.example.com/page-1.jpg"))

        let writingStore = try makeTestOfflineCacheStore(rootDirectory: directory)
        try await writingStore.saveMangaOfflineCacheMembership(
            MangaOfflineCacheMembership(
                ownerName: "作品",
                tid: "900",
                chapterTitle: "第1话",
                imageURLs: [imageURL],
                sourcePage: makeTestMangaOfflineSourcePage(tid: "900")
            )
        )

        let readingStore = try makeTestOfflineCacheStore(rootDirectory: directory)
        let loaded = await readingStore.mangaOfflineCacheMembership(ownerName: "作品", tid: "900")

        #expect(loaded?.id == MangaOfflineCacheMembershipID(ownerName: "作品", tid: "900"))
        #expect(loaded?.chapterTitle == "第1话")
        #expect(loaded?.imageURLs == [imageURL])
    }

    @Test func rereadingMembershipAfterSourcePageContentChangesReturnsFreshDataNotStaleCache() async throws {
        let directory = try makeTemporaryOfflineCacheDirectory()
        let store = try makeTestOfflineCacheStore(rootDirectory: directory)
        let firstImage = try #require(URL(string: "https://img.example.com/replace-1.jpg"))
        let secondImage = try #require(URL(string: "https://img.example.com/replace-2.jpg"))

        try await store.saveMangaOfflineCacheMembership(
            MangaOfflineCacheMembership(
                ownerName: "作品C",
                tid: "700",
                chapterTitle: "第700话",
                imageURLs: [firstImage],
                sourcePage: makeTestMangaOfflineSourcePage(tid: "700")
            )
        )
        let originalLoaded = await store.mangaOfflineCacheMembership(ownerName: "作品C", tid: "700")
        #expect(originalLoaded?.chapterTitle == "第700话")
        #expect(originalLoaded?.imageURLs == [firstImage])

        var updatedSourcePage = makeTestMangaOfflineSourcePage(tid: "700")
        updatedSourcePage.title = "第700话-已更新"
        try await store.saveMangaOfflineCacheMembership(
            MangaOfflineCacheMembership(
                ownerName: "作品C",
                tid: "700",
                chapterTitle: "第700话-已更新",
                imageURLs: [firstImage, secondImage],
                sourcePage: updatedSourcePage
            )
        )

        let reloaded = await store.mangaOfflineCacheMembership(ownerName: "作品C", tid: "700")
        #expect(reloaded?.chapterTitle == "第700话-已更新")
        #expect(reloaded?.imageURLs == [firstImage, secondImage])
        #expect(reloaded?.sourcePage.title == "第700话-已更新")
    }

    @Test func usageReportsStoredOfflineImagesByOwner() async throws {
        let directory = try makeTemporaryOfflineCacheDirectory()
        let store = try makeTestOfflineCacheStore(rootDirectory: directory)
        let firstImage = try #require(URL(string: "https://img.example.com/shared.jpg"))
        let secondImage = try #require(URL(string: "https://img.example.com/second.jpg"))

        try await store.saveOfflineImageData(Data(repeating: 1, count: 3), for: firstImage)
        try await store.saveOfflineImageData(Data(repeating: 2, count: 5), for: secondImage)
        let firstMembership = try makeOfflineMembership(ownerName: "作品A", tid: "1", imageURLs: [firstImage])
        let secondMembership = try makeOfflineMembership(ownerName: "作品B", tid: "2", imageURLs: [firstImage, secondImage])
        try await store.saveMangaOfflineCacheMembership(firstMembership)
        try await store.saveMangaOfflineCacheMembership(secondMembership)

        let usage = await store.mangaOfflineCacheDiskUsageByOwner()
        let firstExpectedBytes = try mangaSourcePageByteCount(firstMembership) + 3
        let secondExpectedBytes = try mangaSourcePageByteCount(secondMembership) + 8

        #expect(usage == [
            MangaOfflineCacheOwnerUsage(ownerName: "作品A", byteCount: firstExpectedBytes),
            MangaOfflineCacheOwnerUsage(ownerName: "作品B", byteCount: secondExpectedBytes)
        ])
    }

    @Test func usageIncludesMembershipOwnerWhenReferencedImagesAreMissing() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryOfflineCacheDirectory())
        let missingImage = try #require(URL(string: "https://img.example.com/missing.jpg"))

        let membership = try makeOfflineMembership(ownerName: "作品A", tid: "1", imageURLs: [missingImage])
        try await store.saveMangaOfflineCacheMembership(membership)
        let expectedBytes = try mangaSourcePageByteCount(membership)

        #expect(await store.mangaOfflineCacheDiskUsageByOwner() == [
            MangaOfflineCacheOwnerUsage(ownerName: "作品A", byteCount: expectedBytes)
        ])
    }

    @Test func usageIncludesUnfinishedWorkOwnerAndStoredWorkImages() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: try makeTemporaryOfflineCacheDirectory())
        let completedImage = try #require(URL(string: "https://img.example.com/work-complete.jpg"))
        let missingImage = try #require(URL(string: "https://img.example.com/work-missing.jpg"))

        try await store.saveOfflineImageData(Data(repeating: 4, count: 6), for: completedImage)
        _ = try await store.enqueueMangaOfflineCacheWork(
            makeOfflineWorkRequest(
                ownerName: "作品Work",
                tid: "40",
                targetImageURLs: [completedImage, missingImage]
            )
        )
        try await store.updateOfflineCacheWorkProgress(
            ownerName: "作品Work",
            tid: "40",
            targetImageURLs: [completedImage, missingImage],
            completedImageURLs: [completedImage],
            currentBytesPerSecond: nil
        )

        #expect(await store.mangaOfflineCacheDiskUsageByOwner() == [
            MangaOfflineCacheOwnerUsage(ownerName: "作品Work", byteCount: 6)
        ])
    }

    @Test func renameOwnerMovesMembershipsAndQueueWorksWithoutDroppingImages() async throws {
        let directory = try makeTemporaryOfflineCacheDirectory()
        let store = try makeTestOfflineCacheStore(rootDirectory: directory)
        let cachedImage = try #require(URL(string: "https://img.example.com/rename-cached.jpg"))
        let workImage = try #require(URL(string: "https://img.example.com/rename-work.jpg"))

        try await store.saveOfflineImageData(Data([1, 2, 3]), for: cachedImage)
        try await store.saveOfflineImageData(Data([4, 5]), for: workImage)
        let membership = try makeOfflineMembership(ownerName: "旧作品名", tid: "1", imageURLs: [cachedImage])
        try await store.saveMangaOfflineCacheMembership(membership)
        _ = try await store.enqueueMangaOfflineCacheWork(makeOfflineWorkRequest(ownerName: "旧作品名", tid: "2", targetImageURLs: [workImage]))
        try await store.updateOfflineCacheWorkProgress(
            ownerName: "旧作品名",
            tid: "2",
            targetImageURLs: [workImage],
            completedImageURLs: [workImage],
            currentBytesPerSecond: 128
        )

        try await store.renameMangaOfflineCacheOwner(from: "旧作品名", to: "新作品名")
        let expectedBytes = try mangaSourcePageByteCount(membership) + 5

        #expect(await store.mangaOfflineCacheMembership(ownerName: "旧作品名", tid: "1") == nil)
        #expect(await store.mangaQueueWork(ownerName: "旧作品名", tid: "2") == nil)
        #expect(await store.mangaOfflineCacheMembership(ownerName: "新作品名", tid: "1")?.ownerName == "新作品名")
        #expect(await store.mangaQueueWork(ownerName: "新作品名", tid: "2")?.ownerName == "新作品名")
        #expect(await store.offlineImageData(for: cachedImage) == Data([1, 2, 3]))
        #expect(await store.offlineImageData(for: workImage) == Data([4, 5]))
        #expect(await store.mangaOfflineCacheDiskUsageByOwner() == [
            MangaOfflineCacheOwnerUsage(ownerName: "新作品名", byteCount: expectedBytes)
        ])
    }

    @Test func deletingMembershipPreservesImagesReferencedByRemainingMemberships() async throws {
        let directory = try makeTemporaryOfflineCacheDirectory()
        let store = try makeTestOfflineCacheStore(rootDirectory: directory)
        let sharedImage = try #require(URL(string: "https://img.example.com/shared.jpg"))
        let firstOnlyImage = try #require(URL(string: "https://img.example.com/first-only.jpg"))

        try await store.saveOfflineImageData(Data([1, 2, 3]), for: sharedImage)
        try await store.saveOfflineImageData(Data([4, 5]), for: firstOnlyImage)
        try await store.saveMangaOfflineCacheMembership(makeOfflineMembership(ownerName: "作品A", tid: "1", imageURLs: [sharedImage, firstOnlyImage]))
        let retainedMembership = try makeOfflineMembership(ownerName: "作品A", tid: "2", imageURLs: [sharedImage])
        try await store.saveMangaOfflineCacheMembership(retainedMembership)

        try await store.removeMangaOfflineCacheMembership(ownerName: "作品A", tid: "1")
        let expectedBytes = try mangaSourcePageByteCount(retainedMembership) + 3

        #expect(await store.mangaOfflineCacheMembership(ownerName: "作品A", tid: "1") == nil)
        #expect(await store.offlineImageData(for: sharedImage) == Data([1, 2, 3]))
        #expect(await store.offlineImageData(for: firstOnlyImage) == nil)
        #expect(await store.mangaOfflineCacheDiskUsageByOwner() == [
            MangaOfflineCacheOwnerUsage(ownerName: "作品A", byteCount: expectedBytes)
        ])
    }

    @Test func deletingOfflineMembershipDoesNotClearMangaIndexCaches() async throws {
        let root = try makeTemporaryOfflineCacheDirectory()
        let offlineStore = try makeTestOfflineCacheStore(rootDirectory: root)
        let directoryStore = try makeTestMangaDirectoryStore(rootDirectory: root)
        let projectionStore = try makeTestMangaReaderProjectionStore(rootDirectory: root)
        let imageURL = try #require(URL(string: "https://img.example.com/offline.jpg"))
        let sourceIdentity = MangaReaderProjectionSourceIdentity(
            tid: "100",
            authorID: "42",
            view: 1
        )

        try await directoryStore.saveDirectory(
            MangaDirectory(
                cleanBookName: "透明目录",
                strategy: .tag,
                sourceKey: "tag:1",
                chapters: [
                    MangaChapter(
                        tid: "100",
                        rawTitle: "第1话",
                        chapterNumber: 1
                    )
                ]
            )
        )
        try await projectionStore.save(
            MangaReaderProjection(
                tid: "100",
                ownerAuthorID: "42",
                chapterTitle: "第1话",
                imageURLs: [imageURL],
                sourceIdentity: sourceIdentity,
                sourceFingerprint: "source"
            )
        )
        try await offlineStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await offlineStore.saveMangaOfflineCacheMembership(makeOfflineMembership(ownerName: "透明目录", tid: "100", imageURLs: [imageURL]))

        try await offlineStore.removeMangaOfflineCacheMembership(ownerName: "透明目录", tid: "100")

        #expect(try await directoryStore.directory(named: "透明目录")?.chapters.map(\.tid) == ["100"])
        #expect(await projectionStore.projection(for: sourceIdentity)?.tid == "100")
        #expect(await offlineStore.offlineImageData(for: imageURL) == nil)
    }

    @Test func clearAllRemovesMembershipAndRetainedOfflineImages() async throws {
        let directory = try makeTemporaryOfflineCacheDirectory()
        let store = try makeTestOfflineCacheStore(rootDirectory: directory)
        let imageURL = try #require(URL(string: "https://img.example.com/clear.jpg"))

        try await store.saveOfflineImageData(Data([7]), for: imageURL)
        try await store.saveMangaOfflineCacheMembership(makeOfflineMembership(ownerName: "作品A", tid: "1", imageURLs: [imageURL]))

        try await store.clearAll()

        #expect(await store.mangaOfflineCacheMembership(ownerName: "作品A", tid: "1") == nil)
        #expect(await store.offlineImageData(for: imageURL) == nil)
        #expect(await store.mangaOfflineCacheDiskUsageByOwner().isEmpty)
    }
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

private func mangaSourcePageByteCount(_ membership: MangaOfflineCacheMembership) throws -> Int {
    try JSONEncoder().encode(membership.sourcePage).count
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

private func makeTemporaryOfflineCacheDirectory() throws -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

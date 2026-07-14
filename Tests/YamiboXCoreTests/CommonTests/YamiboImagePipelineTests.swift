import Foundation
import Testing
@testable import YamiboXCore

@Suite("Yamibo Image Pipeline", .serialized)
struct YamiboImagePipelineTests {
    @Test func sendsCurrentSessionHeadersAndReferer() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=1")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "UnitAgent")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://bbs.yamibo.com/thread-1.html")
            #expect(request.value(forHTTPHeaderField: "Accept")?.contains("image/*") == true)
            return MangaReaderDataTestResponse(data: Data([1, 2, 3]))
        }
        let pipeline = harness.makeImagePipeline()

        let data = try await pipeline.data(
            for: imageSource(refererPageURL: URL(string: "https://bbs.yamibo.com/thread-1.html"))
        )

        #expect(data == Data([1, 2, 3]))
        #expect(harness.requests.count == 1)
    }

    @Test func omitsCookieAndRefererWhenAbsent() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Referer") == nil)
            return MangaReaderDataTestResponse(data: Data([4]))
        }
        let pipeline = harness.makeImagePipeline(
            sessionState: SessionState(cookie: "", userAgent: "UnitAgent")
        )

        _ = try await pipeline.data(for: imageSource())

        #expect(harness.requests.count == 1)
    }

    @Test func offlineScopeHitReturnsOfflineBytesWithoutNetwork() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { _ in
            MangaReaderDataTestResponse(data: Data([9]))
        }
        let scope = try #require(YamiboImageOfflineScope(tid: "100", ownerName: "favorite-a"))
        let offline = RecordingOfflineImageProvider(data: Data([7]))
        let pipeline = harness.makeImagePipeline(offlineImages: offline)

        let data = try await pipeline.data(for: imageSource(offlineScope: scope))

        #expect(data == Data([7]))
        #expect(harness.requests.isEmpty)
        let lookups = await offline.lookups
        #expect(lookups.count == 1)
        #expect(lookups.first?.scope == scope)
        #expect(lookups.first?.url == imageSource().url)
    }

    @Test func sourceWithoutScopeSkipsOfflineLookup() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { _ in
            MangaReaderDataTestResponse(data: Data([5]))
        }
        let offline = RecordingOfflineImageProvider(data: Data([7]))
        let pipeline = harness.makeImagePipeline(offlineImages: offline)

        let data = try await pipeline.data(for: imageSource())

        #expect(data == Data([5]))
        #expect(await offline.lookups.isEmpty)
        #expect(harness.requests.count == 1)
    }

    @Test func offlineMissFallsBackToNetwork() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { _ in
            MangaReaderDataTestResponse(data: Data([6]))
        }
        let scope = try #require(YamiboImageOfflineScope(tid: "100"))
        let offline = RecordingOfflineImageProvider(data: nil)
        let pipeline = harness.makeImagePipeline(offlineImages: offline)

        let data = try await pipeline.data(for: imageSource(offlineScope: scope))

        #expect(data == Data([6]))
        #expect(await offline.lookups.count == 1)
        #expect(harness.requests.count == 1)
    }

    @Test func mapsAuthAndEmptyBodyFailures() async throws {
        let authHarness = MangaReaderDataTestHarness()
        defer { authHarness.reset() }
        authHarness.setHandler { _ in
            MangaReaderDataTestResponse(statusCode: 403, data: Data([1]))
        }
        let authPipeline = authHarness.makeImagePipeline()
        await #expect(throws: YamiboError.notAuthenticated) {
            _ = try await authPipeline.data(for: imageSource())
        }

        let emptyHarness = MangaReaderDataTestHarness()
        defer { emptyHarness.reset() }
        emptyHarness.setHandler { _ in
            MangaReaderDataTestResponse(data: Data())
        }
        let emptyPipeline = emptyHarness.makeImagePipeline()
        await #expect(throws: YamiboError.unreadableBody) {
            _ = try await emptyPipeline.data(for: imageSource())
        }
    }

    @Test func offlineScopeDoesNotAffectCacheIdentity() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { _ in
            MangaReaderDataTestResponse(data: Data([8, 6]))
        }
        let pipeline = harness.makeImagePipeline(offlineImages: RecordingOfflineImageProvider(data: nil))
        let url = try #require(URL(string: "https://img.example.com/cache-identity-\(UUID().uuidString).jpg"))
        let scoped = YamiboImageSource(
            url: url,
            refererPageURL: URL(string: "https://bbs.yamibo.com/thread-1.html"),
            offlineScope: YamiboImageOfflineScope(tid: "100")
        )
        let unscoped = YamiboImageSource(url: url)

        let first = try await pipeline.data(for: scoped)
        try await waitForCachedData(in: pipeline, source: unscoped)
        let second = try await pipeline.data(for: unscoped)

        #expect(first == Data([8, 6]))
        #expect(second == Data([8, 6]))
        #expect(harness.requests.count == 1)
    }

    @Test func clearCacheRemovesCachedBytes() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        harness.setHandler { _ in
            MangaReaderDataTestResponse(data: Data([3]))
        }
        let pipeline = harness.makeImagePipeline()
        let source = imageSource(url: "https://img.example.com/clear-\(UUID().uuidString).jpg")

        _ = try await pipeline.data(for: source)
        try await waitForCachedData(in: pipeline, source: source)
        await pipeline.clearCache()

        #expect(pipeline.cachedData(for: source) == nil)
    }
}

@Suite("Offline Image Scope Lookup", .serialized)
struct OfflineImageScopeLookupTests {
    @Test func mangaMembershipScopeReturnsRetainedBytes() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: makeScopeLookupDirectory())
        let imageURL = try #require(URL(string: "https://img.example.com/offline.jpg"))
        try await store.saveOfflineImageData(Data([7]), for: imageURL)
        try await store.saveMangaOfflineCacheMembership(makeScopeLookupMembership(imageURLs: [imageURL]))
        let scope = try #require(YamiboImageOfflineScope(tid: "100", ownerName: "favorite-a"))

        #expect(await store.offlineImageData(url: imageURL, scope: scope) == Data([7]))
    }

    @Test func mangaScopeRejectsNonMemberURL() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: makeScopeLookupDirectory())
        let memberURL = try #require(URL(string: "https://img.example.com/member.jpg"))
        let strayURL = try #require(URL(string: "https://img.example.com/stray.jpg"))
        try await store.saveOfflineImageData(Data([7]), for: strayURL)
        try await store.saveMangaOfflineCacheMembership(makeScopeLookupMembership(imageURLs: [memberURL]))
        let scope = try #require(YamiboImageOfflineScope(tid: "100", ownerName: "favorite-a"))

        #expect(await store.offlineImageData(url: strayURL, scope: scope) == nil)
    }

    @Test func novelScopeReturnsThreadScopedBytes() async throws {
        let store = try makeTestOfflineCacheStore(rootDirectory: makeScopeLookupDirectory())
        let imageURL = try #require(URL(string: "https://img.example.com/novel-inline.jpg"))
        let request = try NovelOfflineCacheWorkRequest(
            ownerTitle: "小说7013",
            title: "第1页",
            threadID: "7013",
            view: 1,
            authorID: "42",
            targetImageURLs: [imageURL],
            retainsInlineImages: true
        )
        try await store.saveNovelOfflineSourcePage(
            makeScopeLookupNovelSourcePage(tid: "7013"),
            request: request,
            updatedAt: Date(timeIntervalSince1970: 70_130)
        )
        try await store.saveOfflineImageData(Data([1, 3]), for: imageURL)

        let matching = try #require(YamiboImageOfflineScope(tid: "7013"))
        let other = try #require(YamiboImageOfflineScope(tid: "7014"))
        #expect(await store.offlineImageData(url: imageURL, scope: matching) == Data([1, 3]))
        #expect(await store.offlineImageData(url: imageURL, scope: other) == nil)
    }

    @Test func scopeRequiresNonEmptyTid() {
        #expect(YamiboImageOfflineScope(tid: nil) == nil)
        #expect(YamiboImageOfflineScope(tid: "  ") == nil)
        #expect(YamiboImageOfflineScope(tid: " 100 ")?.tid == "100")
        #expect(YamiboImageOfflineScope(tid: "100", ownerName: "  ")?.ownerName == nil)
    }
}

private func imageSource(
    url: String = "https://img.example.com/a.jpg",
    refererPageURL: URL? = nil,
    offlineScope: YamiboImageOfflineScope? = nil
) -> YamiboImageSource {
    YamiboImageSource(
        url: URL(string: url)!,
        refererPageURL: refererPageURL,
        offlineScope: offlineScope
    )
}

private func waitForCachedData(
    in pipeline: YamiboImagePipeline,
    source: YamiboImageSource
) async throws {
    for _ in 0 ..< 20 {
        if pipeline.cachedData(for: source) != nil {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(pipeline.cachedData(for: source) != nil)
}

private actor RecordingOfflineImageProvider: YamiboOfflineImageDataProviding {
    struct Lookup: Equatable {
        var url: URL
        var scope: YamiboImageOfflineScope
    }

    private let data: Data?
    private(set) var lookups: [Lookup] = []

    init(data: Data?) {
        self.data = data
    }

    func offlineImageData(url: URL, scope: YamiboImageOfflineScope) async -> Data? {
        lookups.append(Lookup(url: url, scope: scope))
        return data
    }
}

private func makeScopeLookupDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func makeScopeLookupMembership(imageURLs: [URL]) -> MangaOfflineCacheMembership {
    MangaOfflineCacheMembership(
        ownerName: "favorite-a",
        tid: "100",
        chapterTitle: "第100话",
        imageURLs: imageURLs,
        sourcePage: ForumThreadPage(
            thread: ThreadIdentity(tid: "100"),
            title: "第100话",
            posts: [
                ForumThreadPost(
                    postID: "p-100",
                    author: BlogReaderUser(uid: "author-100", name: "作者"),
                    contentHTML: "",
                    contentText: ""
                )
            ]
        )
    )
}

private func makeScopeLookupNovelSourcePage(tid: String) throws -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "小说\(tid)",
        posts: [
            ForumThreadPost(
                postID: "p-\(tid)-1",
                author: BlogReaderUser(uid: "42", name: "作者"),
                contentHTML: "<strong>第1章</strong><br>正文1",
                contentText: "正文1"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1)
    )
}

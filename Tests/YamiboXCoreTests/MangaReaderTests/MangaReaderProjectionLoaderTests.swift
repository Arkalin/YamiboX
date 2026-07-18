import Foundation
import Testing
@testable import YamiboXCore

@Suite("MangaReaderTests: Reader Projection Loader", .serialized)
struct MangaReaderTestsReaderProjectionLoader {
    @Test func derivesProjectionOnlyFromAuthorScopedThreadPage() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        let requestCounter = RequestCounter()
        harness.setHandler { request in
            requestCounter.increment()
            #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=1")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1")
            if request.url?.absoluteString.contains("authorid=42") == true {
                return MangaReaderDataTestResponse(html: authorScopedMangaHTML(
                    title: "【作者】作品 第12话 - 中文百合漫画区 - 百合会",
                    firstImage: "/images/700-1.jpg",
                    secondImage: "https://img.example.com/700-2.png"
                ))
            }
            return MangaReaderDataTestResponse(html: discoveryHTML(
                title: "【作者】作品 第12话 - 中文百合漫画区 - 百合会",
                authorID: "42",
                imageURL: "https://img.example.com/unfiltered-should-not-appear.jpg"
            ))
        }

        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session, cookie: "auth=1", userAgent: "TestAgent/1"),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore
        )

        let projection = try await loader.loadReaderProjection(MangaReaderProjectionRequest(threadID: "700", view: 5))

        #expect(projection.tid == "700")
        #expect(projection.ownerPostID == "9001")
        #expect(projection.ownerAuthorID == "42")
        #expect(projection.ownerAuthorName == "作者42")
        #expect(projection.chapterTitle == "【作者】作品 第12话")
        #expect(projection.sourceIdentity == MangaReaderProjectionSourceIdentity(
            tid: "700",
            authorID: "42",
            view: 5
        ))
        #expect(!projection.sourceFingerprint.isEmpty)
        #expect(projection.imageURLs.map(\.absoluteString) == [
            "https://bbs.yamibo.com/images/700-1.jpg",
            "https://img.example.com/700-2.png",
        ])
        #expect(!projection.imageURLs.map(\.absoluteString).contains("https://img.example.com/unfiltered-should-not-appear.jpg"))
        #expect(requestCounter.value == 2)
    }

    @Test func reusesProjectionOnlyWhenSourceFingerprintAndIdentityMatch() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        let requestCounter = RequestCounter()
        harness.setHandler { request in
            requestCounter.increment()
            if request.url?.absoluteString.contains("authorid=42") == true {
                return MangaReaderDataTestResponse(html: authorScopedMangaHTML(
                    title: "缓存章节 第1话 - 中文百合漫画区 - 百合会",
                    firstImage: "https://img.example.com/cached-1.jpg",
                    secondImage: "https://img.example.com/cached-2.jpg"
                ))
            }
            return MangaReaderDataTestResponse(html: discoveryHTML(
                title: "缓存章节 第1话 - 中文百合漫画区 - 百合会",
                authorID: "42",
                imageURL: "https://img.example.com/unfiltered.jpg"
            ))
        }

        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore
        )

        let request = MangaReaderProjectionRequest(threadID: "701")
        let first = try await loader.loadReaderProjection(request)
        let second = try await loader.loadReaderProjection(request)

        #expect(first == second)
        #expect(requestCounter.value == 2)
    }

    @Test func staleProjectionIsRegeneratedFromMatchingSourcePage() async throws {
        let fixtures = try ProjectionLoaderFixtures()
        let thread = ThreadIdentity(tid: "702")
        let sourceIdentity = MangaReaderProjectionSourceIdentity(
            tid: "702",
            authorID: "42",
            view: 1
        )
        try await fixtures.projectionStore.save(MangaReaderProjection(
            tid: "702",
            ownerPostID: "old",
            ownerAuthorID: "42",
            chapterTitle: "旧缓存",
            imageURLs: [try #require(URL(string: "https://img.example.com/old.jpg"))],
            sourceIdentity: sourceIdentity,
            sourceFingerprint: "stale"
        ))
        try await fixtures.forumCacheStore.saveThreadPage(
            try ForumThreadPageHTMLParser.parsePage(
                from: authorScopedMangaHTML(
                    title: "新内容 第2话 - 中文百合漫画区 - 百合会",
                    firstImage: "https://img.example.com/new-1.jpg",
                    secondImage: "https://img.example.com/new-2.jpg"
                ),
                thread: thread,
                fallbackTitle: nil
            ),
            thread: thread,
            pageNumber: 1,
            authorID: "42"
        )

        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: MangaReaderDataTestHarness().session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore
        )

        let projection = try await loader.loadReaderProjection(
            MangaReaderProjectionRequest(threadID: "702", authorID: "42")
        )

        #expect(projection.ownerPostID == "9001")
        #expect(projection.chapterTitle == "新内容 第2话")
        #expect(projection.imageURLs.map(\.absoluteString) == [
            "https://img.example.com/new-1.jpg",
            "https://img.example.com/new-2.jpg",
        ])
        #expect(projection.sourceFingerprint != "stale")
    }

    @Test func projectionCacheSaveFailureDoesNotPreventOnlineReading() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { request in
            if request.url?.absoluteString.contains("authorid=42") == true {
                return MangaReaderDataTestResponse(html: authorScopedMangaHTML(
                    title: "保存失败 第1话 - 中文百合漫画区 - 百合会",
                    firstImage: "https://img.example.com/save-failure-1.jpg",
                    secondImage: "https://img.example.com/save-failure-2.jpg"
                ))
            }
            return MangaReaderDataTestResponse(html: discoveryHTML(
                title: "保存失败 第1话 - 中文百合漫画区 - 百合会",
                authorID: "42",
                imageURL: "https://img.example.com/unfiltered.jpg"
            ))
        }

        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: FailingProjectionStore(),
            forumCacheStore: fixtures.forumCacheStore
        )

        let projection = try await loader.loadReaderProjection(
            MangaReaderProjectionRequest(threadID: "703")
        )

        #expect(projection.tid == "703")
        #expect(projection.imageURLs.count == 2)
    }

    @Test func unfilteredThreadPageImagesDoNotMakeReaderProjectionReadable() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { request in
            if request.url?.absoluteString.contains("authorid=42") == true {
                return MangaReaderDataTestResponse(html: authorScopedMangaHTMLWithoutImages(
                    title: "空章节 第1话 - 中文百合漫画区 - 百合会"
                ))
            }
            return MangaReaderDataTestResponse(html: discoveryHTML(
                title: "空章节 第1话 - 中文百合漫画区 - 百合会",
                authorID: "42",
                imageURL: "https://img.example.com/unfiltered-only.jpg"
            ))
        }

        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore
        )

        await #expect(throws: YamiboError.parsingFailed(context: L10n.string("context.current_page_not_manga_chapter"))) {
            _ = try await loader.loadReaderProjection(
                MangaReaderProjectionRequest(threadID: "704")
            )
        }
    }

    @Test func offlineFallbackDerivesProjectionFromDurableSourcePageAndSavesTransparentProjection() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        let offlineSourcePage = try offlineMangaSourcePage(
            tid: "705",
            title: "离线章节 第5话 - 中文百合漫画区 - 百合会",
            imageURLs: [
                "https://img.example.com/offline-705-1.jpg",
                "https://img.example.com/offline-705-2.jpg",
            ]
        )
        try await fixtures.offlineCacheStore.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
            ownerName: "离线漫画",
            tid: "705",
            chapterTitle: "离线章节 第5话",
            imageURLs: offlineSourcePage.posts.flatMap(\.images).compactMap { URL(string: $0.url) },
            sourcePage: offlineSourcePage
        ))
        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore,
            offlineCacheStore: fixtures.offlineCacheStore
        )

        let projection = try await loader.loadReaderProjection(MangaReaderProjectionRequest(
            threadID: "705",
            offlineOwnerName: "离线漫画"
        ))

        #expect(projection.tid == "705")
        #expect(projection.ownerAuthorID == "42")
        #expect(projection.chapterTitle == "离线章节 第5话")
        #expect(projection.imageURLs.map(\.absoluteString) == [
            "https://img.example.com/offline-705-1.jpg",
            "https://img.example.com/offline-705-2.jpg",
        ])
        #expect(await fixtures.projectionStore.projection(for: projection.sourceIdentity) == projection)
    }

    @Test func offlineFallbackReusesValidTransparentProjectionCache() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        let sourcePage = try offlineMangaSourcePage(
            tid: "706",
            title: "预热章节 第6话 - 中文百合漫画区 - 百合会",
            imageURLs: ["https://img.example.com/offline-706.jpg"]
        )
        try await fixtures.offlineCacheStore.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
            ownerName: "离线漫画",
            tid: "706",
            chapterTitle: "预热章节 第6话",
            imageURLs: sourcePage.posts.flatMap(\.images).compactMap { URL(string: $0.url) },
            sourcePage: sourcePage
        ))
        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore,
            offlineCacheStore: fixtures.offlineCacheStore
        )
        let request = MangaReaderProjectionRequest(threadID: "706", offlineOwnerName: "离线漫画")
        let derived = try await loader.loadReaderProjection(request)
        let cachedImageURL = try #require(URL(string: "https://img.example.com/reused-706.jpg"))
        let cachedProjection = MangaReaderProjection(
            tid: "706",
            ownerPostID: "cached-post",
            ownerAuthorID: "42",
            chapterTitle: "复用缓存",
            imageURLs: [cachedImageURL],
            sourceIdentity: derived.sourceIdentity,
            sourceFingerprint: derived.sourceFingerprint
        )
        try await fixtures.projectionStore.save(cachedProjection)

        let reused = try await loader.loadReaderProjection(request)

        #expect(reused == cachedProjection)
    }

    @Test func offlineFallbackRegeneratesStaleTransparentProjectionCache() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        let sourcePage = try offlineMangaSourcePage(
            tid: "707",
            title: "重建章节 第7话 - 中文百合漫画区 - 百合会",
            imageURLs: ["https://img.example.com/offline-707.jpg"]
        )
        try await fixtures.offlineCacheStore.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
            ownerName: "离线漫画",
            tid: "707",
            chapterTitle: "重建章节 第7话",
            imageURLs: sourcePage.posts.flatMap(\.images).compactMap { URL(string: $0.url) },
            sourcePage: sourcePage
        ))
        let identity = MangaReaderProjectionSourceIdentity(
            tid: "707",
            authorID: "42",
            view: 1
        )
        try await fixtures.projectionStore.save(MangaReaderProjection(
            tid: "707",
            ownerPostID: "stale-post",
            ownerAuthorID: "42",
            chapterTitle: "旧透明缓存",
            imageURLs: [try #require(URL(string: "https://img.example.com/stale-707.jpg"))],
            sourceIdentity: identity,
            sourceFingerprint: "stale"
        ))
        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore,
            offlineCacheStore: fixtures.offlineCacheStore
        )

        let projection = try await loader.loadReaderProjection(MangaReaderProjectionRequest(
            threadID: "707",
            offlineOwnerName: "离线漫画"
        ))

        #expect(projection.chapterTitle == "重建章节 第7话")
        #expect(projection.imageURLs.map(\.absoluteString) == ["https://img.example.com/offline-707.jpg"])
        #expect(projection.sourceFingerprint != "stale")
    }

    @Test func offlineFallbackRequiresExplicitOwnerAndMembership() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore,
            offlineCacheStore: fixtures.offlineCacheStore
        )

        await #expect(throws: YamiboError.offline) {
            _ = try await loader.loadReaderProjection(MangaReaderProjectionRequest(threadID: "708"))
        }
        await #expect(throws: YamiboError.offline) {
            _ = try await loader.loadReaderProjection(MangaReaderProjectionRequest(
                threadID: "708",
                offlineOwnerName: "离线漫画"
            ))
        }
    }

    @Test func offlineFallbackRejectsMismatchedSourcePageView() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }
        var sourcePage = try offlineMangaSourcePage(
            tid: "709",
            title: "第二页 第9话 - 中文百合漫画区 - 百合会",
            imageURLs: ["https://img.example.com/offline-709.jpg"]
        )
        sourcePage.pageNavigation = ForumPageNavigation(currentPage: 2, totalPages: 2)
        try await fixtures.offlineCacheStore.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
            ownerName: "离线漫画",
            tid: "709",
            chapterTitle: "第二页 第9话",
            imageURLs: sourcePage.posts.flatMap(\.images).compactMap { URL(string: $0.url) },
            sourcePage: sourcePage
        ))
        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore,
            offlineCacheStore: fixtures.offlineCacheStore
        )

        await #expect(throws: YamiboError.offline) {
            _ = try await loader.loadReaderProjection(MangaReaderProjectionRequest(
                threadID: "709",
                view: 1,
                offlineOwnerName: "离线漫画"
            ))
        }
    }

    @Test func parserFailureDoesNotFallBackToOfflineSourcePage() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { _ in
            MangaReaderDataTestResponse(html: authorScopedMangaHTMLWithoutImages(
                title: "空在线章节 第10话 - 中文百合漫画区 - 百合会"
            ))
        }
        let sourcePage = try offlineMangaSourcePage(
            tid: "710",
            title: "离线可读 第10话 - 中文百合漫画区 - 百合会",
            imageURLs: ["https://img.example.com/offline-710.jpg"]
        )
        try await fixtures.offlineCacheStore.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
            ownerName: "离线漫画",
            tid: "710",
            chapterTitle: "离线可读 第10话",
            imageURLs: sourcePage.posts.flatMap(\.images).compactMap { URL(string: $0.url) },
            sourcePage: sourcePage
        ))
        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore,
            offlineCacheStore: fixtures.offlineCacheStore
        )

        await #expect(throws: YamiboError.parsingFailed(context: L10n.string("context.current_page_not_manga_chapter"))) {
            _ = try await loader.loadReaderProjection(MangaReaderProjectionRequest(
                threadID: "710",
                authorID: "42",
                offlineOwnerName: "离线漫画"
            ))
        }
    }

    @Test func ignoringCacheStillFallsBackAfterOnlineFailure() async throws {
        let harness = MangaReaderDataTestHarness()
        defer { harness.reset() }
        let fixtures = try ProjectionLoaderFixtures()
        harness.setHandler { _ in
            throw URLError(.networkConnectionLost)
        }
        let sourcePage = try offlineMangaSourcePage(
            tid: "711",
            title: "强刷离线 第11话 - 中文百合漫画区 - 百合会",
            imageURLs: ["https://img.example.com/offline-711.jpg"]
        )
        try await fixtures.offlineCacheStore.saveMangaOfflineCacheMembership(MangaOfflineCacheMembership(
            ownerName: "离线漫画",
            tid: "711",
            chapterTitle: "强刷离线 第11话",
            imageURLs: sourcePage.posts.flatMap(\.images).compactMap { URL(string: $0.url) },
            sourcePage: sourcePage
        ))
        let loader = MangaReaderProjectionLoader(
            client: YamiboClient(session: harness.session),
            projectionStore: fixtures.projectionStore,
            forumCacheStore: fixtures.forumCacheStore,
            offlineCacheStore: fixtures.offlineCacheStore
        )

        let projection = try await loader.loadReaderProjectionIgnoringCache(MangaReaderProjectionRequest(
            threadID: "711",
            authorID: "42",
            offlineOwnerName: "离线漫画"
        ))

        #expect(projection.imageURLs.map(\.absoluteString) == ["https://img.example.com/offline-711.jpg"])
    }
}

private struct ProjectionLoaderFixtures {
    var projectionStore: MangaReaderProjectionStore
    var forumCacheStore: ForumCacheStore
    var offlineCacheStore: OfflineCacheStore

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = try YamiboDatabase.openPool(rootDirectory: root.appendingPathComponent("grdb", isDirectory: true))
        projectionStore = MangaReaderProjectionStore(databasePool: database, rootDirectory: root)
        forumCacheStore = ForumCacheStore(databasePool: database, rootDirectory: root)
        offlineCacheStore = OfflineCacheStore(
            databasePool: database,
            baseDirectory: root.appendingPathComponent("offline-cache", isDirectory: true)
        )
    }
}

private actor FailingProjectionStore: MangaReaderProjectionPersisting {
    func projection(for identity: MangaReaderProjectionSourceIdentity) async -> MangaReaderProjection? {
        nil
    }

    func save(_ projection: MangaReaderProjection) async throws {
        throw YamiboPersistenceError(context: "projection save failed")
    }

    func clearAll() async throws {}
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func discoveryHTML(title: String, authorID: String, imageURL: String) -> String {
    """
    <html>
      <head><title>\(title)</title></head>
      <body>
        <div id="post_8001">
          <div class="authi"><a href="home.php?mod=space&uid=\(authorID)">作者\(authorID)</a></div>
          <div id="postmessage_8001" class="message">
            <img src="\(imageURL)" />
          </div>
        </div>
      </body>
    </html>
    """
}

private func authorScopedMangaHTML(title: String, firstImage: String, secondImage: String) -> String {
    """
    <html>
      <head><title>\(title)</title></head>
      <body>
        <div id="post_9001">
          <div class="authi"><a href="home.php?mod=space&uid=42">作者42</a></div>
          <div id="postmessage_9001" class="message">
            <img zsrc="\(firstImage)" />
            <img src="\(secondImage)" />
          </div>
        </div>
      </body>
    </html>
    """
}

private func authorScopedMangaHTMLWithoutImages(title: String) -> String {
    """
    <html>
      <head><title>\(title)</title></head>
      <body>
        <div id="post_9001">
          <div class="authi"><a href="home.php?mod=space&uid=42">作者42</a></div>
          <div id="postmessage_9001" class="message">no manga images here</div>
        </div>
      </body>
    </html>
    """
}

private func offlineMangaSourcePage(tid: String, title: String, imageURLs: [String]) throws -> ForumThreadPage {
    let images = imageURLs.map { ForumThreadPostImage(url: $0) }
    return ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: title,
        posts: [
            ForumThreadPost(
                postID: "offline-\(tid)",
                author: BlogReaderUser(uid: "42", name: "作者42"),
                contentHTML: imageURLs.map { #"<img src="\#($0)" />"# }.joined(),
                contentText: "",
                images: images
            )
        ]
    )
}

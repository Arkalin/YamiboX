import Foundation
import Testing
@testable import YamiboXCore

// 拆分自 ReaderCoreTests.swift:NovelReaderRepository 加载/缓存/离线回退链路,
// 以及按 threadID 的 by-id API。StubURLProtocol 与 makeTestOfflineCacheStore、
// novelReaderProjectionCacheFiles 位于 NovelReaderTestSupport.swift。

@Test func readerRepositoryDoesNotCrossHitFilteredCacheWhenOffline() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: cacheStore,
        forumCacheStore: forumCacheStore
    )
    let authorFiltered = NovelReaderProjection(
        threadID: "22",
        view: 1,
        maxView: 2,
        resolvedAuthorID: "42",
        segments: [.text("只看楼主缓存", chapterTitle: "第一章")]
    )
    try await cacheStore.save(authorFiltered)

    await #expect(throws: YamiboError.offline) {
        _ = try await repository.loadPage(NovelPageRequest(threadID: "22", view: 1))
    }

    await #expect(throws: YamiboError.offline) {
        _ = try await repository.loadPage(NovelPageRequest(threadID: "22", view: 1, authorID: "42"))
    }
}

@Test func readerRepositoryLoadsProjectionFromCachedAuthorScopedThreadPage() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "32")
    try await forumCacheStore.saveThreadPage(
        makeReaderRepositoryThreadPage(
            thread: thread,
            title: "缓存小说",
            postID: "3201",
            authorID: "42",
            contentHTML: "<strong>第一章</strong><br>缓存正文"
        ),
        thread: thread,
        pageNumber: 1,
        authorID: "42"
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore
    )

    let document = try await repository.loadPage(NovelPageRequest(threadID: "32", view: 1, authorID: "42"))

    #expect(document.resolvedAuthorID == "42")
    #expect(document.segments.contains(.text("第一章\n缓存正文", chapterTitle: "第一章")))
    #expect(document.projectionSourceFingerprint != nil)
    #expect(await repository.cachedViews(for: "32", authorID: "42") == [1])
}

@Test func readerRepositoryPersistsProjectionDerivedFromCachedAuthorScopedThreadPage() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let readerCacheDirectory = directory.appendingPathComponent("reader", isDirectory: true)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: readerCacheDirectory)
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "3201")
    try await forumCacheStore.saveThreadPage(
        makeReaderRepositoryThreadPage(
            thread: thread,
            title: "缓存小说",
            postID: "320101",
            authorID: "42",
            contentHTML: "<strong>第一章</strong><br>缓存正文"
        ),
        thread: thread,
        pageNumber: 1,
        authorID: "42"
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore
    )

    let document = try await repository.loadPage(NovelPageRequest(threadID: "3201", view: 1, authorID: "42"))
    let persisted = await NovelReaderProjectionStore(baseDirectory: readerCacheDirectory).loadProjection(
        for: NovelPageRequest(threadID: "3201", view: 1, authorID: "42")
    )

    #expect(persisted?.threadID == document.threadID)
    #expect(persisted?.view == document.view)
    #expect(persisted?.resolvedAuthorID == document.resolvedAuthorID)
    #expect(persisted?.segments == document.segments)
    #expect(persisted?.segmentSources == document.segmentSources)
    #expect(persisted?.segmentSemantics == document.segmentSemantics)
    #expect(persisted?.projectionSourceFingerprint == document.projectionSourceFingerprint)
    #expect(persisted?.projectionSchemaVersion == document.projectionSchemaVersion)
}

@Test func readerRepositoryRepairsProjectionCacheDirectoryDeletedDuringRuntime() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let readerCacheDirectory = directory.appendingPathComponent("reader", isDirectory: true)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: readerCacheDirectory)
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "3202")
    try await forumCacheStore.saveThreadPage(
        makeReaderRepositoryThreadPage(
            thread: thread,
            title: "运行中删缓存",
            postID: "320201",
            authorID: "42",
            contentHTML: "<strong>第一章</strong><br>缓存正文"
        ),
        thread: thread,
        pageNumber: 1,
        authorID: "42"
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore
    )

    _ = try await repository.loadPage(NovelPageRequest(threadID: "3202", view: 1, authorID: "42"))
    try FileManager.default.removeItem(
        at: YamiboDatabase.cacheDirectoryURL(rootDirectory: readerCacheDirectory)
            .appendingPathComponent(NovelReaderProjectionStore.projectionNamespace, isDirectory: true)
    )
    let document = try await repository.loadPage(NovelPageRequest(threadID: "3202", view: 1, authorID: "42"))
    let persisted = await NovelReaderProjectionStore(baseDirectory: readerCacheDirectory).loadProjection(
        for: NovelPageRequest(threadID: "3202", view: 1, authorID: "42")
    )

    #expect(persisted?.segments == document.segments)
    #expect(persisted?.projectionSourceFingerprint == document.projectionSourceFingerprint)
}

@Test func readerRepositoryDoesNotUseLegacyReaderProjectionWithoutThreadPage() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    try await novelReaderCacheStore.save(
        NovelReaderProjection(
            threadID: "33",
            view: 1,
            maxView: 1,
            resolvedAuthorID: "42",
            segments: [.text("旧 reader projection", chapterTitle: "旧章")]
        )
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore
    )

    await #expect(throws: (any Error).self) {
        _ = try await repository.loadPage(NovelPageRequest(threadID: "33", view: 1, authorID: "42"))
    }

    #expect(await repository.cachedViews(for: "33", authorID: "42").isEmpty)
}

private func makeReaderRepositoryThreadPage(
    thread: ThreadIdentity,
    title: String,
    postID: String,
    authorID: String,
    contentHTML: String,
    page: Int = 1,
    totalPages: Int = 1
) -> ForumThreadPage {
    ForumThreadPage(
        thread: thread,
        title: title,
        posts: [
            ForumThreadPost(
                postID: postID,
                author: BlogReaderUser(uid: authorID, name: "楼主"),
                contentHTML: contentHTML,
                contentText: "ignored"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: page, totalPages: totalPages)
    )
}

@Test func readerRepositoryRefreshesOnlyCurrentVariantCache() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: cacheStore,
        forumCacheStore: forumCacheStore
    )
    let unfiltered = NovelReaderProjection(
        threadID: "23",
        view: 1,
        maxView: 2,
        segments: [.text("全部回复旧缓存", chapterTitle: "第一章")]
    )
    let authorFiltered = NovelReaderProjection(
        threadID: "23",
        view: 1,
        maxView: 2,
        resolvedAuthorID: "42",
        segments: [.text("只看楼主旧缓存", chapterTitle: "第一章")]
    )
    try await cacheStore.save(unfiltered)
    try await cacheStore.save(authorFiltered)

    try await repository.refreshCachedViews(
        [1],
        for: "23",
        authorID: "42"
    )

    let refreshedAuthorFiltered = await cacheStore.loadProjection(
        for: NovelPageRequest(threadID: "23", view: 1, authorID: "42")
    )
    let preservedUnfiltered = await cacheStore.loadProjection(
        for: NovelPageRequest(threadID: "23", view: 1)
    )

    let refreshedText = refreshedAuthorFiltered?.segments.compactMap { segment -> String? in
        if case let .text(text, _) = segment { return text }
        return nil
    }.first
    let preservedText = preservedUnfiltered?.segments.compactMap { segment -> String? in
        if case let .text(text, _) = segment { return text }
        return nil
    }.first

    #expect(refreshedText == "只看楼主新缓存")
    #expect(preservedText == "全部回复旧缓存")
}

@Test func readerRepositoryRefreshesCachedDocumentsBeforeAuthorReplyMetadataSchema() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStoreDirectory = directory.appendingPathComponent("reader", isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: cacheStoreDirectory)
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    try await cacheStore.save(
        NovelReaderProjection(
            threadID: "30",
            view: 1,
            maxView: 1,
            resolvedAuthorID: "42",
            segments: [.text("旧 schema 缓存正文", chapterTitle: "第一章")]
        )
    )
    try rewriteCachedReaderDocumentSchemaVersion(in: cacheStoreDirectory, to: 3)
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: cacheStoreDirectory),
        forumCacheStore: forumCacheStore
    )

    let document = try await repository.loadPage(NovelPageRequest(threadID: "30", view: 1, authorID: "42"))
    let text = document.segments.compactMap { segment -> String? in
        if case let .text(text, _) = segment { return text }
        return nil
    }.first

    #expect(text == "新 schema 缓存刷新正文")
}

@Test func readerRepositoryDoesNotFallBackToOldSchemaProjectionWhenThreadPageRefreshIsOffline() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStoreDirectory = directory.appendingPathComponent("reader", isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: cacheStoreDirectory)
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    try await cacheStore.save(
        NovelReaderProjection(
            threadID: "31",
            view: 1,
            maxView: 1,
            resolvedAuthorID: "42",
            segments: [.text("旧 schema 离线缓存正文", chapterTitle: "第一章")]
        )
    )
    try rewriteCachedReaderDocumentSchemaVersion(in: cacheStoreDirectory, to: 3)
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: cacheStoreDirectory),
        forumCacheStore: forumCacheStore
    )

    await #expect(throws: YamiboError.offline) {
        _ = try await repository.loadPage(NovelPageRequest(threadID: "31", view: 1, authorID: "42"))
    }
}

@Test func readerRepositoryFallsBackToDurableNovelOfflineSourcePageWhenOnlineAcquisitionFails() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "34")
    let sourcePage = makeReaderRepositoryThreadPage(
        thread: thread,
        title: "离线小说",
        postID: "3401",
        authorID: "42",
        contentHTML: "<strong>离线章节</strong><br>离线正文"
    )
    let updatedAt = Date(timeIntervalSince1970: 34_000)
    try await offlineStore.saveNovelOfflineSourcePage(
        sourcePage,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "离线小说",
            title: "第一页",
            threadID: "34",
            view: 1,
            authorID: "42"
        ),
        updatedAt: updatedAt
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore,
        offlineCacheStore: offlineStore
    )

    let load = try await repository.loadPageResult(NovelPageRequest(threadID: "34", view: 1, authorID: "42"))
    let prewarm = await novelReaderCacheStore.loadProjection(
        for: NovelPageRequest(threadID: "34", view: 1, authorID: "42")
    )

    #expect(load.source == .offlineFallback(updatedAt: updatedAt))
    #expect(load.projection.segments.contains(.text("离线章节\n离线正文", chapterTitle: "离线章节")))
    #expect(load.projection.projectionSourceFingerprint != nil)
    #expect(load.projection.projectionSchemaVersion == 1)
    #expect(prewarm?.segments == load.projection.segments)
}

@Test func readerRepositoryOfflineFallbackReusesValidTransparentProjectionCache() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let novelReaderCacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let thread = ThreadIdentity(tid: "341")
    let sourcePage = makeReaderRepositoryThreadPage(
        thread: thread,
        title: "离线小说",
        postID: "34101",
        authorID: "42",
        contentHTML: "<strong>离线章节</strong><br>离线正文"
    )
    let updatedAt = Date(timeIntervalSince1970: 341_000)
    try await offlineStore.saveNovelOfflineSourcePage(
        sourcePage,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "离线小说",
            title: "第一页",
            threadID: "341",
            view: 1,
            authorID: "42"
        ),
        updatedAt: updatedAt
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: novelReaderCacheStore,
        forumCacheStore: forumCacheStore,
        offlineCacheStore: offlineStore
    )
    let parsedLoad = try await repository.loadPageResult(NovelPageRequest(threadID: "341", view: 1, authorID: "42"))
    let fingerprint = try #require(parsedLoad.projection.projectionSourceFingerprint)
    let cachedProjection = NovelReaderProjection(
        threadID: parsedLoad.projection.threadID,
        view: 1,
        maxView: parsedLoad.projection.maxView,
        resolvedAuthorID: "42",
        segments: [.text("透明缓存正文", chapterTitle: "透明缓存章节")],
        projectionSourceFingerprint: fingerprint,
        projectionSchemaVersion: parsedLoad.projection.projectionSchemaVersion
    )
    try await novelReaderCacheStore.save(cachedProjection)

    let cachedLoad = try await repository.loadPageResult(NovelPageRequest(threadID: "341", view: 1, authorID: "42"))

    #expect(cachedLoad.source == .offlineFallback(updatedAt: updatedAt))
    #expect(cachedLoad.projection.segments == cachedProjection.segments)
}

@Test func readerRepositoryDoesNotUseOfflineFallbackForParserFailures() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let thread = ThreadIdentity(tid: "35")
    let sourcePage = makeReaderRepositoryThreadPage(
        thread: thread,
        title: "离线小说",
        postID: "3501",
        authorID: "42",
        contentHTML: "<strong>离线章节</strong><br>离线正文"
    )
    try await offlineStore.saveNovelOfflineSourcePage(
        sourcePage,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "离线小说",
            title: "第一页",
            threadID: "35",
            view: 1,
            authorID: "42"
        ),
        updatedAt: Date(timeIntervalSince1970: 35_000)
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true)),
        forumCacheStore: ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true)),
        offlineCacheStore: offlineStore
    )

    await #expect(throws: (any Error).self) {
        _ = try await repository.loadPageResult(NovelPageRequest(threadID: "35", view: 1, authorID: "42"))
    }
}

@Test func readerRepositoryAutoRefreshesExistingNovelOfflineSourceAfterOnlineRead() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let thread = ThreadIdentity(tid: "36")
    let oldSource = makeReaderRepositoryThreadPage(
        thread: thread,
        title: "自动刷新小说",
        postID: "3600",
        authorID: "42",
        contentHTML: "<strong>旧章节</strong><br>旧正文"
    )
    let oldUpdatedAt = Date(timeIntervalSince1970: 36_000)
    try await offlineStore.saveNovelOfflineSourcePage(
        oldSource,
        request: NovelOfflineCacheWorkRequest(
            ownerTitle: "自动刷新小说",
            title: "第一页",
            threadID: "36",
            view: 1,
            authorID: "42"
        ),
        updatedAt: oldUpdatedAt
    )
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true)),
        forumCacheStore: ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true)),
        offlineCacheStore: offlineStore,
        novelOfflineAutoRefreshEnabled: { true }
    )

    let load = try await repository.loadPageResult(NovelPageRequest(threadID: "36", view: 1, authorID: "42"))
    let refreshedSource = await offlineStore.novelOfflineSourcePage(
        ownerTitle: "自动刷新小说",
        threadID: "36",
        view: 1,
        authorID: "42"
    )
    let snapshot = await offlineStore.novelOfflineCacheViewsSnapshot(
        ownerTitle: "自动刷新小说",
        threadID: "36",
        authorID: "42"
    )

    #expect(load.source == .online)
    #expect(load.projection.segments.contains(.text("在线章节\n在线新正文", chapterTitle: "在线章节")))
    #expect(refreshedSource?.posts.first?.contentHTML.contains("在线新正文") == true)
    #expect((snapshot.updateTimesByView[1] ?? oldUpdatedAt) > oldUpdatedAt)
}

@Test func readerRepositoryDoesNotCreateNovelOfflineEntryForUncachedOnlineRead() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let offlineStore = try makeTestOfflineCacheStore(rootDirectory: directory)
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true)),
        forumCacheStore: ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true)),
        offlineCacheStore: offlineStore,
        novelOfflineAutoRefreshEnabled: { true }
    )

    _ = try await repository.loadPageResult(NovelPageRequest(threadID: "37", view: 1, authorID: "42"))
    let snapshot = await offlineStore.novelOfflineCacheViewsSnapshot(
        ownerTitle: "未缓存小说",
        threadID: "37",
        authorID: "42"
    )

    #expect(snapshot.cachedViews.isEmpty)
    #expect(await offlineStore.allNovelOfflineCacheEntries().isEmpty)
}

@Test func readerRepositoryCachesViewsSequentiallyAndSkipsFailures() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: cacheStore,
        forumCacheStore: forumCacheStore
    )
    let result = await repository.cacheViews(
        [1, 2, 3],
        for: "24",
        authorID: "42"
    )

    #expect(result.completedViews == [1, 3])
    #expect(result.failedViews == [2])
    #expect(!result.wasCancelled)
    #expect(await repository.cachedViews(for: "24", authorID: "42") == [1, 3])
    #expect(await cacheStore.cachedViews(for: "24", authorID: nil).isEmpty)
}

@Test func readerRepositoryRefreshesLegacyCacheMissingChapterCommentSources() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = NovelReaderProjectionStore(baseDirectory: directory.appendingPathComponent("reader", isDirectory: true))
    let forumCacheStore = ForumCacheStore(baseDirectory: directory.appendingPathComponent("forum", isDirectory: true))
    let repository = NovelReaderRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA"),
        cacheStore: cacheStore,
        forumCacheStore: forumCacheStore
    )
    let legacyDocument = NovelReaderProjection(
        threadID: "25",
        view: 1,
        maxView: 1,
        resolvedAuthorID: "42",
        retainedChapterCount: 1,
        segments: [.text("旧缓存章节\n旧正文", chapterTitle: "旧缓存章节")]
    )
    try await cacheStore.save(legacyDocument)

    let loaded = try await repository.loadPage(NovelPageRequest(threadID: "25", view: 1, authorID: "42"))

    #expect(loaded.segments == [.text("新解析章节\n新正文", chapterTitle: "新解析章节")])
    #expect(loaded.source(forSegmentIndex: 0)?.ownerPostID == "41257246")
}

private func rewriteCachedReaderDocumentSchemaVersion(in directory: URL, to version: Int) throws {
    let fileURL = try #require(novelReaderProjectionCacheFiles(rootDirectory: directory).first)
    let data = try Data(contentsOf: fileURL)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    object["schemaVersion"] = version
    let output = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try output.write(to: fileURL, options: [.atomic])
}

@Suite("NovelReaderRepository by-id APIs", .serialized)
private struct NovelReaderRepositoryByIDTests {
    @Test func fetchThreadDisplayTitleUsesThreadIDRequest() async throws {
        defer { NovelReaderRepositoryByIDURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NovelReaderRepositoryByIDURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let repository = NovelReaderRepository(
            client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
        )

        NovelReaderRepositoryByIDURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []
            let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in
                item.value.map { (item.name, $0) }
            })
            #expect(values["tid"] == "3210")
            #expect(values["page"] == "1")
            #expect(values["authorid"] == "42")
            #expect(request.url?.absoluteString.contains("thread-") == false)
            return (
                Data("<html><head><title>By ID Title</title></head><body></body></html>".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let title = try await repository.fetchThreadDisplayTitle(threadID: "3210", authorID: "42")

        #expect(title == "By ID Title")
    }
}

private final class NovelReaderRepositoryByIDURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Data, HTTPURLResponse)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

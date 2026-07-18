import Foundation
import Testing
@testable import YamiboXCore

// 拆分自 ReaderCoreTests.swift:ReaderChapterCommentsRepository 章评加载
// (只看楼主页评分、全帖页楼间回复、URL 缓存策略、redirect 定位真实全帖页)。
// StubURLProtocol 位于 NovelReaderTestSupport.swift。

@Test func readerChapterCommentsRepositoryLoadsChapterCommentsFromAuthorFilteredPageWhenTargetHasAuthorID() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = ReaderChapterCommentsRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
    )
    let target = ReaderChapterCommentTarget(
        threadID: "26",
        view: 2,
        ownerPostID: "2601",
        title: "episode 16",
        authorID: "42"
    )

    let page = try await repository.loadChapterComments(for: target)

    #expect(page.comments.map(\.body) == ["完整评分理由"])
}

@Test func readerChapterCommentsRepositoryLoadsSamePageRepliesFromUnfilteredPageForAuthorFilteredTarget() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = ReaderChapterCommentsRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
    )
    let target = ReaderChapterCommentTarget(
        threadID: "27",
        view: 2,
        ownerPostID: "2701",
        title: "第一章",
        authorID: "42"
    )

    let page = try await repository.loadChapterComments(for: target)

    #expect(page.comments.map(\.source) == [.reply])
    #expect(page.comments.map(\.authorName) == ["读者甲"])
    #expect(page.comments.map(\.body) == ["楼间回复"])
    #expect(page.isBoundaryClosed == true)
    #expect(page.nextView == nil)
}

@Test func readerChapterCommentsRepositoryReloadsUnfilteredRepliesIgnoringURLCache() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = ReaderChapterCommentsRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
    )
    let target = ReaderChapterCommentTarget(
        threadID: "28",
        view: 2,
        ownerPostID: "2801",
        title: "第一章",
        authorID: "42"
    )
    // StubURLProtocol 是全局单 handler(所有用例共享按 URL 分发的默认路由)。
    // 这里为本用例临时替换 handler:包装默认路由、把 tid=28 全帖页(非
    // authorid=42)请求的 cachePolicy 记录到本用例的局部记录盒,用例结束(defer)
    // 立即恢复默认 handler。包装器对所有请求原样委托默认路由,因此并行运行的
    // 其他用例不受影响。这取代了旧的 tid28UnfilteredCachePolicy 跨测试可变
    // 静态信道——断言只依赖本用例自己的局部状态。
    let recordedUnfilteredCachePolicy = LockedRecordedValue<URLRequest.CachePolicy>()
    let defaultHandler = StubURLProtocol.defaultHandler()
    StubURLProtocol.handler = { request in
        let absolute = request.url?.absoluteString ?? ""
        if absolute.contains("tid=28") || absolute.contains("ptid=28"),
           !absolute.contains("authorid=42") {
            recordedUnfilteredCachePolicy.record(request.cachePolicy)
        }
        return defaultHandler(request)
    }
    defer { StubURLProtocol.handler = StubURLProtocol.defaultHandler() }

    let page = try await repository.loadChapterComments(for: target)

    #expect(page.comments.map(\.body) == ["楼间回复"])
    #expect(recordedUnfilteredCachePolicy.value == .reloadIgnoringLocalCacheData)
}

@Test func readerChapterCommentsRepositoryFindsRealUnfilteredPageForAuthorFilteredChapterComments() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let repository = ReaderChapterCommentsRepository(
        client: YamiboClient(session: session, cookie: "sid=reader", userAgent: "Test-UA")
    )
    let target = ReaderChapterCommentTarget(
        threadID: "29",
        view: 2,
        ownerPostID: "2901",
        title: "第一章",
        authorID: "42"
    )

    let page = try await repository.loadChapterComments(for: target)

    #expect(page.comments.map(\.body) == ["真实全帖页回复"])
    #expect(page.nextView == 5)
}

/// URLProtocol 回调可能在 URLSession 内部队列执行,用锁保护单值写入/读取。
private final class LockedRecordedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        lock.withLock { stored }
    }

    func record(_ value: Value) {
        lock.withLock { stored = value }
    }
}

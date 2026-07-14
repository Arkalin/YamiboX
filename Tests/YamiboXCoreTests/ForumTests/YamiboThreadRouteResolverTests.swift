import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

private final class YamiboThreadRouteResolverTestURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: YamiboThreadRouteResolverTestError.missingHandler)
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

private enum YamiboThreadRouteResolverTestError: Error {
    case missingHandler
}

@Suite(.serialized)
struct YamiboThreadRouteResolverTests {

@Test func yamiboThreadRouteResolverUsesContainingBoardForNovelThreadsWithoutFetching() async throws {
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=100&mobile=2")),
        title: "小说标题",
        authorID: "705216",
        tapContext: YamiboThreadTapContext(containingFid: "49")
    )

    let target = try await resolver.resolve(request)

    guard case let .novel(context) = target else {
        Issue.record("Expected novel detail target, got \(target)")
        return
    }
    #expect(context.thread.tid == "100")
    #expect(context.title == "小说标题")
    #expect(context.authorID == "705216")
}

@Test func yamiboThreadRouteResolverUsesLightNovelSubBoardForNovelDetail() async throws {
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=101&extra=page%3D1&mobile=2&page=25&authorid=705217")),
        title: "轻小说标题",
        authorID: "705217",
        tapContext: YamiboThreadTapContext(containingFid: "55")
    )

    let target = try await resolver.resolve(request)

    guard case let .novel(context) = target else {
        Issue.record("Expected novel detail target, got \(target)")
        return
    }
    #expect(context.thread.tid == "101")
    #expect(context.thread.fid == "55")
    #expect(context.title == "轻小说标题")
    #expect(context.authorID == "705217")
}

// `knownThreadKind` still classifies a fid the configuration doesn't cover,
// but an unconfigured board never reports Smart Comic Mode on (one rule, no
// special cases), so the route is the direct single-thread manga reader.
@Test func yamiboThreadRouteResolverUsesKnownMangaKindWhenConfigurationMisses() async throws {
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=200&mobile=2")),
        title: "漫画标题",
        threadFid: "999999",
        knownThreadKind: .manga
    )

    let target = try await resolver.resolve(request)

    guard case let .mangaDirect(context) = target else {
        Issue.record("Expected direct-to-reader manga target, got \(target)")
        return
    }
    #expect(context.thread.tid == "200")
    #expect(context.thread.fid == "999999")
    #expect(context.title == "漫画标题")
}

// smart-comic-mode design decision #1/#2/#12: fid 46 defaults to Smart
// Comic Mode off, so a manga-kind thread there should route directly to the
// reader instead of `ForumMangaDetailView`.
@Test func yamiboThreadRouteResolverRoutesDirectlyToMangaReaderWhenBoardModeIsOff() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "route-resolver-smart-comic-mode-default")
    let settingsStore = try SettingsStore(testSuiteName: suiteName, key: "settings")
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient(), settingsStore: settingsStore)
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=800&mobile=2")),
        title: "漫画标题",
        knownThreadKind: .manga,
        tapContext: YamiboThreadTapContext(containingFid: "46")
    )

    let target = try await resolver.resolve(request)

    guard case let .mangaDirect(payload) = target else {
        Issue.record("Expected direct-to-reader manga target, got \(target)")
        return
    }
    #expect(payload.thread.tid == "800")
    #expect(payload.thread.fid == "46")
    #expect(payload.title == "漫画标题")
}

// Same board, but with its toggle explicitly turned on: routing must fall
// back to today's `ForumMangaDetailView` behavior.
@Test func yamiboThreadRouteResolverRoutesToMangaDetailWhenBoardModeIsOn() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "route-resolver-smart-comic-mode-enabled")
    let settingsStore = try SettingsStore(testSuiteName: suiteName, key: "settings")
    var settings = await settingsStore.load()
    settings.boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
    try await settingsStore.save(settings)
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient(), settingsStore: settingsStore)
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=801&mobile=2")),
        title: "漫画标题",
        knownThreadKind: .manga,
        tapContext: YamiboThreadTapContext(containingFid: "46")
    )

    let target = try await resolver.resolve(request)

    guard case let .manga(payload) = target else {
        Issue.record("Expected manga detail target, got \(target)")
        return
    }
    #expect(payload.thread.tid == "801")
    #expect(payload.thread.fid == "46")
}

// A board with no configuration entry never reports Smart Comic Mode on —
// even a thread explicitly classified as manga via `knownThreadKind` opens
// the reader directly instead of `ForumMangaDetailView`.
@Test func yamiboThreadRouteResolverRoutesDirectlyToMangaReaderForUnconfiguredBoard() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "route-resolver-smart-comic-mode-out-of-scope")
    let settingsStore = try SettingsStore(testSuiteName: suiteName, key: "settings")
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient(), settingsStore: settingsStore)
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=802&mobile=2")),
        title: "漫画标题",
        threadFid: "999999",
        knownThreadKind: .manga
    )

    let target = try await resolver.resolve(request)

    guard case .mangaDirect = target else {
        Issue.record("Expected direct-to-reader manga target, got \(target)")
        return
    }
}

// Pluggable-reader-config decision #1: ANY board — not just the old
// hardcoded taxonomy's five — routes by whatever reader mode the user
// configured for it. fid "99" has no factory entry at all.
@Test func yamiboThreadRouteResolverRoutesArbitraryBoardConfiguredAsNovelToNovelReader() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "route-resolver-arbitrary-board-novel")
    let settingsStore = try SettingsStore(testSuiteName: suiteName, key: "settings")
    var settings = await settingsStore.load()
    settings.boardReader.setEntry(.init(mode: .novel), forumID: "99")
    try await settingsStore.save(settings)
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient(), settingsStore: settingsStore)
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=900&mobile=2")),
        title: "任意板块小说",
        authorID: "705300",
        tapContext: YamiboThreadTapContext(containingFid: "99")
    )

    let target = try await resolver.resolve(request)

    guard case let .novel(context) = target else {
        Issue.record("Expected novel detail target, got \(target)")
        return
    }
    #expect(context.thread.tid == "900")
    #expect(context.thread.fid == "99")
    #expect(context.title == "任意板块小说")
}

// Same arbitrary board, configured manga with the smart bit ON: routing goes
// to the manga detail page (`.manga`), exactly like the factory smart board.
@Test func yamiboThreadRouteResolverRoutesArbitraryBoardConfiguredMangaSmartOnToMangaDetail() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "route-resolver-arbitrary-board-manga-smart-on")
    let settingsStore = try SettingsStore(testSuiteName: suiteName, key: "settings")
    var settings = await settingsStore.load()
    settings.boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "99")
    try await settingsStore.save(settings)
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient(), settingsStore: settingsStore)
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=901&mobile=2")),
        title: "任意板块漫画",
        tapContext: YamiboThreadTapContext(containingFid: "99")
    )

    let target = try await resolver.resolve(request)

    guard case let .manga(payload) = target else {
        Issue.record("Expected manga detail target, got \(target)")
        return
    }
    #expect(payload.thread.tid == "901")
    #expect(payload.thread.fid == "99")
}

// Manga without the smart bit: still the manga reader, but directly
// (`.mangaDirect`), skipping the detail page.
@Test func yamiboThreadRouteResolverRoutesArbitraryBoardConfiguredMangaSmartOffDirectlyToReader() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "route-resolver-arbitrary-board-manga-smart-off")
    let settingsStore = try SettingsStore(testSuiteName: suiteName, key: "settings")
    var settings = await settingsStore.load()
    settings.boardReader.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "99")
    try await settingsStore.save(settings)
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient(), settingsStore: settingsStore)
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=902&mobile=2")),
        title: "任意板块漫画",
        tapContext: YamiboThreadTapContext(containingFid: "99")
    )

    let target = try await resolver.resolve(request)

    guard case let .mangaDirect(payload) = target else {
        Issue.record("Expected direct-to-reader manga target, got \(target)")
        return
    }
    #expect(payload.thread.tid == "902")
    #expect(payload.thread.fid == "99")
}

// Removing the same board's entry (the settings overview's 移除 action)
// drops it straight back to the plain native thread reader — no entry means
// no special routing of any kind (pluggable-reader-config decision #3).
@Test func yamiboThreadRouteResolverFallsBackToThreadReaderWhenBoardEntryIsRemoved() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "route-resolver-arbitrary-board-entry-removed")
    let settingsStore = try SettingsStore(testSuiteName: suiteName, key: "settings")
    var settings = await settingsStore.load()
    settings.boardReader.setEntry(.init(mode: .novel), forumID: "99")
    try await settingsStore.save(settings)
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient(), settingsStore: settingsStore)
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=903&mobile=2")),
        title: "撤销配置的帖子",
        tapContext: YamiboThreadTapContext(containingFid: "99")
    )

    let configuredTarget = try await resolver.resolve(request)
    guard case .novel = configuredTarget else {
        Issue.record("Expected novel detail target while configured, got \(configuredTarget)")
        return
    }

    settings = await settingsStore.load()
    settings.boardReader.removeEntry(forumID: "99")
    try await settingsStore.save(settings)

    let target = try await resolver.resolve(request)

    guard case let .thread(context) = target else {
        Issue.record("Expected native thread reader target after removal, got \(target)")
        return
    }
    #expect(context.thread.tid == "903")
    #expect(context.thread.fid == "99")
    #expect(context.title == "撤销配置的帖子")
}

@Test func yamiboThreadRouteResolverNativeThreadIntentBypassesNovelClassification() async throws {
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=201&page=4&mobile=2")),
        title: "小说原帖",
        authorID: "705216",
        intent: .nativeThreadReader,
        tapContext: YamiboThreadTapContext(containingFid: "49")
    )

    let target = try await resolver.resolve(request)

    guard case let .thread(context) = target else {
        Issue.record("Expected native thread reader target, got \(target)")
        return
    }
    #expect(context.thread.tid == "201")
    #expect(context.thread.fid == "49")
    #expect(context.title == "小说原帖")
    #expect(context.initialPage == 4)
    #expect(context.authorID == "705216")
}

@Test func yamiboThreadRouteResolverNativeThreadIntentBypassesMangaClassification() async throws {
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=202&mobile=2")),
        title: "漫画原帖",
        threadFid: "999999",
        knownThreadKind: .manga,
        intent: .nativeThreadReader
    )

    let target = try await resolver.resolve(request)

    guard case let .thread(context) = target else {
        Issue.record("Expected native thread reader target, got \(target)")
        return
    }
    #expect(context.thread.tid == "202")
    #expect(context.thread.fid == "999999")
    #expect(context.title == "漫画原帖")
}

@Test func yamiboThreadRouteResolverNativeThreadIntentExtractsTargetPostFromFragment() async throws {
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=203&page=5&mobile=2#pid9901")),
        title: "原帖",
        intent: .nativeThreadReader
    )

    let target = try await resolver.resolve(request)

    guard case let .thread(context) = target else {
        Issue.record("Expected native thread reader target, got \(target)")
        return
    }
    #expect(context.thread.tid == "203")
    #expect(context.initialPage == 5)
    #expect(context.targetPostID == "9901")
}

@Test func yamiboThreadRouteResolverDefaultsUnknownBoardToNativeThreadReader() async throws {
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=300&page=2&mobile=2")),
        title: "普通帖子",
        threadFid: "999999",
        targetPostID: "42"
    )

    let target = try await resolver.resolve(request)

    guard case let .thread(context) = target else {
        Issue.record("Expected native thread reader target, got \(target)")
        return
    }
    #expect(context.thread.tid == "300")
    #expect(context.thread.fid == "999999")
    #expect(context.initialPage == 2)
    #expect(context.targetPostID == "42")
}

@Test func yamiboThreadRouteResolverExtractsInitialPageFromRewriteThreadURL() async throws {
    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClient())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/thread-301-4-1.html")),
        title: "普通帖子",
        threadFid: "999999"
    )

    let target = try await resolver.resolve(request)

    guard case let .thread(context) = target else {
        Issue.record("Expected native thread reader target, got \(target)")
        return
    }
    #expect(context.thread.tid == "301")
    #expect(context.initialPage == 4)
}

@Test func yamiboThreadRouteResolverNormalizesFindPostURLAndCarriesTargetPost() async throws {
    defer { YamiboThreadRouteResolverTestURLProtocol.handler = nil }

    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClientWithHandler())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=redirect&goto=findpost&ptid=302&pid=9001&mobile=2")),
        title: "普通帖子",
        threadFid: "999999"
    )
    YamiboThreadRouteResolverTestURLProtocol.handler = { request in
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.value(named: "goto") == "findpost")
        #expect(items.value(named: "ptid") == "302")
        #expect(items.value(named: "pid") == "9001")
        return yamiboThreadRouteHTTPResponse(
            url: request.url!,
            body: #"""
            <html>
            <head><title>普通帖子 - 百合会</title></head>
            <body>
              <div id="post_9001">
                <div class="authi">
                  <a class="author" href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主名</a>
                  <em>发表于 2026-6-1 10:00</em>
                </div>
                <div class="message" id="postmessage_9001">目标回复</div>
              </div>
              <div class="pg"><a>1</a><a>2</a><strong>3</strong><span>/ 5 页</span></div>
            </body>
            </html>
            """#
        )
    }

    let target = try await resolver.resolve(request)

    guard case let .thread(context) = target else {
        Issue.record("Expected native thread reader target, got \(target)")
        return
    }
    #expect(context.thread.tid == "302")
    #expect(context.initialPage == 3)
    #expect(context.targetPostID == "9001")
}

@Test func yamiboThreadRouteResolverNativeThreadIntentKeepsFindPostTargetWhenPageResolutionFails() async throws {
    defer { YamiboThreadRouteResolverTestURLProtocol.handler = nil }

    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClientWithHandler())
    let request = YamiboThreadRouteRequest(
        threadURL: try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=redirect&goto=findpost&ptid=303&pid=9002&mobile=2")),
        title: "原帖",
        intent: .nativeThreadReader
    )
    YamiboThreadRouteResolverTestURLProtocol.handler = { request in
        yamiboThreadRouteHTTPResponse(url: request.url!, body: "forbidden", statusCode: 403)
    }

    let target = try await resolver.resolve(request)

    guard case let .thread(context) = target else {
        Issue.record("Expected native thread reader target, got \(target)")
        return
    }
    #expect(context.thread.tid == "303")
    #expect(context.initialPage == 1)
    #expect(context.targetPostID == "9002")
}

@Test func yamiboThreadRouteResolverFetchesYamiboThreadMetadataWhenBoardIsUnknown() async throws {
    defer { YamiboThreadRouteResolverTestURLProtocol.handler = nil }

    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClientWithHandler())
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=400&mobile=2"))

    YamiboThreadRouteResolverTestURLProtocol.handler = { request in
        #expect(request.url?.path == "/forum.php")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.value(named: "tid") == "400")
        return yamiboThreadRouteHTTPResponse(
            url: request.url!,
            body: #"""
            <html>
            <head><title>章节标题 - 文学区 - 百合会</title></head>
            <body>
              <div class="header"><h2><a href="forum.php?mod=forumdisplay&amp;fid=49&amp;mobile=2">文学区</a></h2></div>
              <a href="home.php?mod=space&amp;uid=88&amp;mobile=2" class="mmc">作者</a>
            </body>
            </html>
            """#
        )
    }

    let target = try await resolver.resolve(YamiboThreadRouteRequest(threadURL: url))

    guard case let .novel(context) = target else {
        Issue.record("Expected novel detail target, got \(target)")
        return
    }
    #expect(context.thread.tid == "400")
    #expect(context.thread.fid == "49")
    #expect(context.title == "章节标题 - 文学区 - 百合会")
    #expect(context.authorID == "88")
}

@Test func yamiboThreadRouteResolverUsesNovelMarkerWhenBoardMetadataIsMissing() async throws {
    defer { YamiboThreadRouteResolverTestURLProtocol.handler = nil }

    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClientWithHandler())
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=401&mobile=2"))

    YamiboThreadRouteResolverTestURLProtocol.handler = { request in
        yamiboThreadRouteHTTPResponse(
            url: request.url!,
            body: #"""
            <html>
            <head><title>文學區 - 测试帖子 - 百合会</title></head>
            <body><div class="message">正文</div></body>
            </html>
            """#
        )
    }

    let target = try await resolver.resolve(YamiboThreadRouteRequest(threadURL: url))

    guard case let .novel(context) = target else {
        Issue.record("Expected novel target, got \(target)")
        return
    }
    #expect(context.thread.tid == "401")
    #expect(context.title == "文學區 - 测试帖子 - 百合会")
}

@Test func yamiboThreadRouteResolverUsesWebFallbackForAuthenticatedMetadataFailure() async throws {
    defer { YamiboThreadRouteResolverTestURLProtocol.handler = nil }

    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClientWithHandler())
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=500&mobile=2"))

    YamiboThreadRouteResolverTestURLProtocol.handler = { request in
        yamiboThreadRouteHTTPResponse(url: request.url!, body: "forbidden", statusCode: 403)
    }

    let target = try await resolver.resolve(YamiboThreadRouteRequest(threadURL: url))

    guard case let .webFallback(fallbackURL) = target else {
        Issue.record("Expected web fallback target, got \(target)")
        return
    }
    #expect(fallbackURL == url)
}

@Test func yamiboThreadRouteResolverPropagatesNonFallbackMetadataFailure() async throws {
    defer { YamiboThreadRouteResolverTestURLProtocol.handler = nil }

    let resolver = YamiboThreadRouteResolver(client: yamiboThreadRouteTestClientWithHandler())
    let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=600&mobile=2"))

    YamiboThreadRouteResolverTestURLProtocol.handler = { request in
        yamiboThreadRouteHTTPResponse(url: request.url!, body: "")
    }

    await #expect(throws: YamiboError.emptyHTML) {
        _ = try await resolver.resolve(YamiboThreadRouteRequest(threadURL: url))
    }
}

}

private func yamiboThreadRouteTestClient() -> YamiboClient {
    YamiboClient(session: URLSession(configuration: .ephemeral), userAgent: "Test-UA")
}

private func yamiboThreadRouteTestClientWithHandler() -> YamiboClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [YamiboThreadRouteResolverTestURLProtocol.self]
    return YamiboClient(session: URLSession(configuration: configuration), userAgent: "Test-UA")
}

private func yamiboThreadRouteHTTPResponse(
    url: URL,
    body: String,
    statusCode: Int = 200
) -> (Data, HTTPURLResponse) {
    (
        Data(body.utf8),
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    )
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}

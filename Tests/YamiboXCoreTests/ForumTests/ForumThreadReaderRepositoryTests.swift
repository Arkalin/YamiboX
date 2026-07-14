import Foundation
import Testing
@testable import YamiboXCore

private final class ForumThreadReaderRepositoryTestURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: ForumThreadReaderRepositoryTestError.missingHandler)
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

private enum ForumThreadReaderRepositoryTestError: Error {
    case missingHandler
}

@Suite(.serialized)
private struct ForumThreadReaderRepositoryTests {
@Test func forumThreadReaderRepositoryCachesFetchedThreadPages() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = ForumCacheStore(baseDirectory: directory)
    let threadURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=704&mobile=2"))
    let thread = ThreadIdentity(tid: "704")
    let repository = ForumThreadReaderRepository(
        client: YamiboClient(session: makeForumThreadReaderRepositoryTestSession(), cookie: "auth=token", userAgent: "Test-UA"),
        cacheStore: cacheStore
    )

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(items.value(named: "tid") == "704")
        #expect(items.value(named: "page") == "2")
        #expect(items.value(named: "authorid") == nil)
        return forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: forumThreadReaderRepositoryThreadHTML(title: "普通缓存页", postID: "4002")
        )
    }

    let loaded = try await repository.fetchThreadPage(
        context: ThreadNovelLaunchContext(thread: thread, title: "上下文标题"),
        page: 2
    )

    #expect(loaded.title == "普通缓存页")
    #expect(await repository.cachedThreadPage(
        context: ThreadNovelLaunchContext(thread: thread, title: "上下文标题"),
        page: 2
    )?.title == "普通缓存页")
    #expect(await repository.cachedThreadPage(thread: thread, title: "上下文标题", authorID: nil, page: 2)?.title == "普通缓存页")
}

@Test func forumThreadReaderRepositoryCachesFetchedNovelThreadPagesByAuthor() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = ForumCacheStore(baseDirectory: directory)
    let threadURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=705&mobile=2"))
    let thread = ThreadIdentity(tid: "705")
    let repository = ForumThreadReaderRepository(
        client: YamiboClient(session: makeForumThreadReaderRepositoryTestSession(), cookie: "auth=token", userAgent: "Test-UA"),
        cacheStore: cacheStore
    )

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(items.value(named: "tid") == "705")
        #expect(items.value(named: "page") == "1")
        #expect(items.value(named: "authorid") == "42")
        return forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: forumThreadReaderRepositoryThreadHTML(title: "作者缓存页", postID: "5001")
        )
    }

    let context = NovelDetailLaunchContext(thread: thread, title: "小说标题", authorID: "42")
    let loaded = try await repository.fetchNovelThreadPage(context: context, page: 1)

    #expect(loaded.title == "作者缓存页")
    #expect(await repository.cachedNovelThreadPage(context: context, page: 1)?.title == "作者缓存页")
    #expect(await repository.cachedThreadPage(thread: thread, title: "小说标题", authorID: "42", page: 1)?.title == "作者缓存页")
    #expect(await repository.cachedThreadPage(thread: thread, title: "小说标题", authorID: nil, page: 1) == nil)
}

@Test func forumThreadReaderRepositoryCanReplaceThreadPageCacheAfterRefresh() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = ForumCacheStore(baseDirectory: directory)
    let threadURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=708&mobile=2"))
    let thread = ThreadIdentity(tid: "708")
    let repository = ForumThreadReaderRepository(
        client: YamiboClient(session: makeForumThreadReaderRepositoryTestSession(), cookie: "auth=token", userAgent: "Test-UA"),
        cacheStore: cacheStore
    )

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: forumThreadReaderRepositoryThreadHTML(title: "刷新前缓存页", postID: "8001")
        )
    }

    let context = NovelDetailLaunchContext(thread: thread, title: "小说标题", authorID: "42")
    let loaded = try await repository.fetchNovelThreadPage(context: context, page: 1)
    #expect(await repository.cachedNovelThreadPage(context: context, page: 1)?.title == "刷新前缓存页")

    try await repository.clearCachedThreadPages(thread: thread)
    #expect(await repository.cachedNovelThreadPage(context: context, page: 1) == nil)

    var refreshed = loaded
    refreshed.title = "刷新后缓存页"
    try await repository.storeNovelThreadPage(refreshed, context: context, pageNumber: 1)
    #expect(await repository.cachedNovelThreadPage(context: context, page: 1)?.title == "刷新后缓存页")
}

@Test func forumThreadReaderRepositoryInteractionRequestsDoNotWriteThreadPageCache() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheStore = ForumCacheStore(baseDirectory: directory)
    let threadURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=706&mobile=2"))
    let thread = ThreadIdentity(tid: "706")
    let repository = ForumThreadReaderRepository(
        client: YamiboClient(session: makeForumThreadReaderRepositoryTestSession(), cookie: "auth=token", userAgent: "Test-UA"),
        cacheStore: cacheStore
    )

    func expectNoThreadPageCache() async {
        #expect(await cacheStore.loadThreadPage(thread: thread, page: 1, authorID: nil, allowExpired: true) == nil)
    }

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <html><body>
              <table>
                <tr><th>参与人数 1</th><th>积分 +2</th><th>理由</th></tr>
                <tr><td><a href="home.php?mod=space&amp;uid=77">读者甲</a></td><td>+2</td><td>好</td></tr>
              </table>
            </body></html>
            """#
        )
    }

    _ = try await repository.fetchRatingResults(threadID: "706", postID: "6001")
    await expectNoThreadPageCache()

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <root><![CDATA[
              <select id="rate1"><option value="1">1</option></select>
            ]]></root>
            """#
        )
    }
    _ = try await repository.fetchRateOptions(threadID: "706", postID: "6001")
    await expectNoThreadPageCache()

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <html><body>
              <select><option value="12" selected="selected">选项乙</option></select>
              <a href="home.php?mod=space&amp;uid=88">读者乙</a>
            </body></html>
            """#
        )
    }
    _ = try await repository.fetchPollVoters(threadID: "706", optionID: "12")
    await expectNoThreadPageCache()

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"<html><body><div class="jump_c">投票成功</div></body></html>"#
        )
    }
    _ = try await repository.votePoll(
        forumID: "49",
        threadID: "706",
        optionIDs: ["12"],
        formHash: "form123"
    )
    await expectNoThreadPageCache()

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <root><![CDATA[
              <div id="messagetext"><p>评分成功</p></div>
              <script>succeedhandle_rate();</script>
            ]]></root>
            """#
        )
    }
    _ = try await repository.ratePost(
        threadID: "706",
        postID: "6001",
        score: 1,
        reason: "好",
        formHash: "form123",
        noticeAuthor: false
    )
    await expectNoThreadPageCache()

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <root><![CDATA[
              <div id="messagetext"><p>点评成功</p></div>
              <script>succeedhandle_comment();</script>
            ]]></root>
            """#
        )
    }
    _ = try await repository.commentPost(
        threadID: "706",
        postID: "6001",
        message: "喜欢",
        formHash: "form123"
    )
    await expectNoThreadPageCache()
}

@Test func forumThreadReaderRepositoryFetchesRatingResultsNatively() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let repository = ForumThreadReaderRepository(
        client: YamiboClient(
            session: makeForumThreadReaderRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.url?.path == "/forum.php")
        #expect(items.value(named: "mod") == "misc")
        #expect(items.value(named: "action") == "viewratings")
        #expect(items.value(named: "tid") == "704")
        #expect(items.value(named: "pid") == "4001")
        #expect(items.value(named: "mobile") == "2")
        return forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <html><body>
              <table>
                <tr><th>参与人数 1</th><th>积分 +2</th><th>理由</th></tr>
                <tr><td><a href="home.php?mod=space&amp;uid=77">读者甲</a></td><td>+2</td><td>好</td></tr>
              </table>
            </body></html>
            """#
        )
    }

    let page = try await repository.fetchRatingResults(threadID: "704", postID: "4001")

    #expect(page.ratings.count == 1)
    #expect(page.ratings.first?.user.uid == "77")
}

@Test func forumThreadReaderRepositoryFetchesRateOptionsNatively() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let repository = ForumThreadReaderRepository(
        client: YamiboClient(
            session: makeForumThreadReaderRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.url?.path == "/forum.php")
        #expect(items.value(named: "mod") == "misc")
        #expect(items.value(named: "action") == "rate")
        #expect(items.value(named: "tid") == "704")
        #expect(items.value(named: "pid") == "4001")
        #expect(items.value(named: "mobile") == "2")
        #expect(items.value(named: "infloat") == "yes")
        #expect(items.value(named: "handlekey") == "rate")
        #expect(items.value(named: "inajax") == "1")
        return forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <root><![CDATA[
              <select id="rate1"><option value="1">1</option><option value="5">5</option></select>
              <select id="reason"><option value="好萌">好萌</option></select>
            ]]></root>
            """#
        )
    }

    let page = try await repository.fetchRateOptions(threadID: "704", postID: "4001")

    #expect(page.availableScores == [1, 5])
    #expect(page.defaultReasons == ["好萌"])
}

@Test func forumThreadReaderRepositoryFetchesPollVotersNatively() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let repository = ForumThreadReaderRepository(
        client: YamiboClient(
            session: makeForumThreadReaderRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.url?.path == "/forum.php")
        #expect(items.value(named: "mod") == "misc")
        #expect(items.value(named: "action") == "viewvote")
        #expect(items.value(named: "tid") == "704")
        #expect(items.value(named: "polloptionid") == "12")
        #expect(items.value(named: "page") == "3")
        #expect(items.value(named: "mobile") == "2")
        return forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <html><body>
              <select><option value="12" selected="selected">选项乙</option></select>
              <a href="home.php?mod=space&amp;uid=88">读者乙</a>
            </body></html>
            """#
        )
    }

    let page = try await repository.fetchPollVoters(threadID: "704", optionID: "12", page: 3)

    #expect(page.selectedOptionID == "12")
    #expect(page.voters.first?.uid == "88")
}

@Test func forumThreadReaderRepositoryVotesPollNatively() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let repository = ForumThreadReaderRepository(
        client: YamiboClient(
            session: makeForumThreadReaderRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )
    var postedBody = ""

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.url?.path == "/forum.php")
        #expect(items.value(named: "mod") == "misc")
        #expect(items.value(named: "action") == "votepoll")
        #expect(items.value(named: "fid") == "123")
        #expect(items.value(named: "tid") == "704")
        #expect(items.value(named: "mobile") == "2")
        postedBody = String(
            data: request.forumThreadReaderRepositoryHTTPBodyData(),
            encoding: .utf8
        ) ?? ""
        return forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"<html><body><div class="jump_c">投票成功</div></body></html>"#
        )
    }

    let message = try await repository.votePoll(
        forumID: "123",
        threadID: "704",
        optionIDs: ["11", "12"],
        formHash: "form123"
    )

    #expect(message == "投票成功")
    #expect(postedBody.contains("formhash=form123"))
    #expect(postedBody.contains("pollsubmit=true"))
    #expect(postedBody.contains("quickforward=yes"))
    #expect(postedBody.contains("pollanswers%5B%5D=11"))
    #expect(postedBody.contains("pollanswers%5B%5D=12"))
}

@Test func forumThreadReaderRepositoryRatesPostNatively() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let repository = ForumThreadReaderRepository(
        client: YamiboClient(
            session: makeForumThreadReaderRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )
    var postedBody = ""

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.url?.path == "/forum.php")
        #expect(items.value(named: "mod") == "misc")
        #expect(items.value(named: "action") == "rate")
        #expect(items.value(named: "ratesubmit") == "yes")
        #expect(items.value(named: "infloat") == "yes")
        #expect(items.value(named: "handlekey") == "rateform")
        #expect(items.value(named: "inajax") == "1")
        postedBody = String(data: request.forumThreadReaderRepositoryHTTPBodyData(), encoding: .utf8) ?? ""
        return forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <root><![CDATA[
              <div id="messagetext"><p>评分成功</p></div>
              <script>succeedhandle_rate();</script>
            ]]></root>
            """#
        )
    }

    let message = try await repository.ratePost(
        threadID: "704",
        postID: "4001",
        score: 5,
        reason: "好萌",
        formHash: "form123",
        noticeAuthor: true
    )

    #expect(message == "评分成功")
    #expect(postedBody.contains("formhash=form123"))
    #expect(postedBody.contains("tid=704"))
    #expect(postedBody.contains("pid=4001"))
    #expect(postedBody.contains("referer="))
    #expect(postedBody.contains("handlekey=rate"))
    #expect(postedBody.contains("score1=5"))
    #expect(postedBody.contains("reason=%E5%A5%BD%E8%90%8C"))
    #expect(postedBody.contains("sendreasonpm=on"))
}

@Test func forumThreadReaderRepositoryCommentsPostNatively() async throws {
    defer { ForumThreadReaderRepositoryTestURLProtocol.handler = nil }

    let repository = ForumThreadReaderRepository(
        client: YamiboClient(
            session: makeForumThreadReaderRepositoryTestSession(),
            cookie: "auth=token",
            userAgent: "Test-UA"
        )
    )
    var postedBody = ""

    ForumThreadReaderRepositoryTestURLProtocol.handler = { request in
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=token")
        #expect(request.url?.path == "/forum.php")
        #expect(items.value(named: "mod") == "post")
        #expect(items.value(named: "action") == "reply")
        #expect(items.value(named: "comment") == "yes")
        #expect(items.value(named: "tid") == "704")
        #expect(items.value(named: "pid") == "4001")
        #expect(items.value(named: "extra") == "")
        #expect(items.value(named: "page") == "2")
        #expect(items.value(named: "commentsubmit") == "yes")
        #expect(items.value(named: "infloat") == "yes")
        #expect(items.value(named: "handlekey") == "commentform")
        #expect(items.value(named: "inajax") == "1")
        postedBody = String(data: request.forumThreadReaderRepositoryHTTPBodyData(), encoding: .utf8) ?? ""
        return forumThreadReaderRepositoryHTTPResponse(
            url: request.url!,
            body: #"""
            <root><![CDATA[
              <div id="messagetext"><p>点评成功</p></div>
              <script>succeedhandle_comment();</script>
            ]]></root>
            """#
        )
    }

    let message = try await repository.commentPost(
        threadID: "704",
        postID: "4001",
        message: "喜欢",
        formHash: "form123",
        page: 2
    )

    #expect(message == "点评成功")
    #expect(postedBody.contains("formhash=form123"))
    #expect(postedBody.contains("handlekey="))
    #expect(postedBody.contains("message=%E5%96%9C%E6%AC%A2"))
}

private func makeForumThreadReaderRepositoryTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForumThreadReaderRepositoryTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func forumThreadReaderRepositoryHTTPResponse(
    url: URL,
    body: String,
    statusCode: Int = 200
) -> (Data, HTTPURLResponse) {
    (
        Data(body.utf8),
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    )
}

private func forumThreadReaderRepositoryThreadHTML(title: String, postID: String) -> String {
    #"""
    <html>
    <head><title>\#(title) - 百合会</title></head>
    <body>
      <div id="post_\#(postID)">
        <div class="authi">
          <em title="楼主">楼主</em>
          <a class="author" href="home.php?mod=space&amp;uid=42&amp;mobile=2">楼主名</a>
          <em>发表于 2026-6-1 10:00</em>
        </div>
        <div class="message" id="postmessage_\#(postID)">正文</div>
      </div>
    </body>
    </html>
    """#
}
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}

private extension URLRequest {
    func forumThreadReaderRepositoryHTTPBodyData() -> Data {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

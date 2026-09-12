import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI
import YamiboXTestSupport

@MainActor
@Suite(.serialized)
struct ReaderChapterCommentComposerIntegrationTests {
    @Test(arguments: [ReaderChapterCommentComposeMode.comment, .rating], [true, false])
    func nativeSubmissionNotifiesOriginalThreadOnlyOnSuccess(mode: ReaderChapterCommentComposeMode, accepted: Bool) async throws {
        try await withContext(findPostHTML: ChapterComposerIntegrationHTML.touchThread, submissionAccepted: accepted) { context in
            let refreshState = ForumContentRefreshState()
            var changes: [ForumSubmissionChange] = []
            let model = try makeModel(context: context, mode: mode) { change in
                changes.append(change)
                refreshState.record(change)
            }
            await model.load()
            #expect(changes.isEmpty)
            if mode == .comment {
                model.comment?.message = "A chapter comment"
            } else {
                model.rating?.scoreText = "5"
                model.rating?.reason = "Great chapter"
            }
            #expect(model.canSubmit)

            let feedback = await model.submit()
            #expect((feedback != nil) == accepted)
            #expect(model.didSubmit == accepted)
            #expect(changes.count == (accepted ? 1 : 0))
            #expect(refreshState.threadChange("123")?.kind == (accepted ? .postInteraction(threadID: "123") : nil))
            #expect(refreshState.threadChange("999") == nil)
            #expect(ChapterComposerIntegrationURLProtocol.record.requests.filter { $0.httpMethod == "POST" }.count == 1)
        }
    }

    @Test(arguments: ReaderChapterCommentComposeMode.allCases)
    func touchTemplateLoadsThroughProductionDependencies(mode: ReaderChapterCommentComposeMode) async throws {
        try await withContext(findPostHTML: ChapterComposerIntegrationHTML.touchThread) { context in
            let model = try makeModel(context: context, mode: mode)
            await model.load()

            let postContext = try #require(model.context)
            #expect(postContext.threadID == "123")
            #expect(postContext.post.postID == "456")
            #expect(postContext.post.author.uid == "42")
            #expect(postContext.post.author.name == "南枝")
            #expect(postContext.page == 9)
            #expect(postContext.formHash == "a1b2c3d4")
            #expect(postContext.replyURL.queryItemValue("repquote") == "456")
            #expect(postContext.replyURL.queryItemValue("page") == "9")
            #expect(model.authorName == "南枝")
            #expect(model.mode == mode)
            let comment = try #require(model.comment)
            #expect(!model.canSubmit)

            var expectedURLs = [try #require(YamiboRoute.findPostURL(threadID: "123", postID: "456"))]
            switch mode {
            case .comment:
                comment.message = "A chapter comment"
            case .rating:
                let rating = try #require(model.rating)
                let options = try #require(rating.options)
                #expect(options.availableScores == [1, 5])
                #expect(options.defaultReasons == ["Great chapter"])
                #expect(!rating.isLoadingOptions)
                rating.scoreText = "5"
                expectedURLs.append(YamiboRoute.threadRateOptions(tid: "123", pid: "456").url)
            case .reply:
                let session = try #require(model.replySession)
                let form = try #require(model.replyForm)
                let field = try #require(form.fields.first { $0.name == "message" })
                #expect(form.kind == .thread)
                #expect(form.hiddenValues.contains(.init(name: "formhash", value: "reply-token")))
                #expect(model.replyButton != nil)
                #expect(!session.isLoading)
                #expect(!session.submissionSucceeded)
                #expect(session.pendingSubmission == nil)
                session.drafts[form.id]?[field.id] = ["[quote]Chapter[/quote]A reply"]
                expectedURLs.append(YamiboRoute.threadPostReply(tid: "123", pid: "456", page: 9).url)
            }

            #expect(model.canSubmit)
            #expect(!model.isLoading)
            #expect(!model.isBusy)
            #expect(!model.didSubmit)
            #expect(model.feedback == nil)
            #expect(model.comment?.errorMessage == nil)
            #expect(model.rating?.errorMessage == nil)
            #expect(model.replySession?.errorMessage == nil)
            #expect(model.replySession?.errorDetails == nil)
            #expect(model.replySession?.transientFeedback == nil)

            let requests = ChapterComposerIntegrationURLProtocol.record.requests
            #expect(requests.compactMap(\.url) == expectedURLs)
            assertReadOnlyAuthenticatedRequests(requests)
            let findPost = try #require(requests.first)
            #expect(findPost.url?.queryItemValue("authorid") == nil)
            #expect(findPost.url?.queryItemValue("page") == nil)
            #expect(findPost.cachePolicy == .reloadIgnoringLocalCacheData)
        }
    }

    @Test func actualLoginPageBlocksEveryModeDespiteSavedCredentials() async throws {
        try await withContext(findPostHTML: ChapterComposerIntegrationHTML.loginPage) { context in
            for mode in ReaderChapterCommentComposeMode.allCases {
                let model = try makeModel(context: context, mode: mode)
                await model.load()

                #expect(model.context == nil)
                #expect(model.comment == nil)
                #expect(model.rating == nil)
                #expect(model.replySession == nil)
                #expect(model.replyForm == nil)
                #expect(model.feedback != nil)
                #expect(!model.isLoading)
                #expect(!model.canSubmit)
                #expect(await model.submit() == nil)
                #expect(!model.didSubmit)
            }

            let requests = ChapterComposerIntegrationURLProtocol.record.requests
            let findPostURL = try #require(YamiboRoute.findPostURL(threadID: "123", postID: "456"))
            #expect(requests.compactMap(\.url) == Array(repeating: findPostURL, count: 3))
            assertReadOnlyAuthenticatedRequests(requests)
        }
    }

    private func makeModel(
        context: YamiboAppContext,
        mode: ReaderChapterCommentComposeMode,
        onSubmissionAccepted: @escaping (ForumSubmissionChange) -> Void = { _ in Issue.record("Loading must not accept a submission") }
    ) throws -> ReaderChapterCommentComposerModel {
        let chapter = ReaderChapterCommentTarget(
            threadID: "123", view: 2, ownerPostID: "456", title: "Chapter", authorID: "42"
        )
        let target = try #require(ReaderChapterCommentComposeTarget.owner(chapter))
        #expect(target.authorName == nil)
        let model = ReaderChapterCommentComposerModel(
            target: target,
            actions: ReaderChapterCommentComposeActions(
                dependencies: context.forumDependencies,
                onSubmissionAccepted: onSubmissionAccepted
            )
        )
        model.selectMode(mode)
        return model
    }

    private func assertReadOnlyAuthenticatedRequests(_ requests: [URLRequest]) {
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.httpBodyStream == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "EeqY_2132_auth=test")
            #expect(request.httpShouldHandleCookies == false)
        }
    }

    private func withContext(
        findPostHTML: String,
        submissionAccepted: Bool? = nil,
        body: (YamiboAppContext) async throws -> Void
    ) async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "chapter-composer-integration")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        ChapterComposerIntegrationURLProtocol.record.configure(findPostHTML: findPostHTML, submissionAccepted: submissionAccepted)
        defer { ChapterComposerIntegrationURLProtocol.record.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChapterComposerIntegrationURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let sessionStore = SessionStore(defaults: defaults)
        try await sessionStore.save(SessionState(cookie: "EeqY_2132_auth=test", isLoggedIn: true))
        let context = YamiboAppContext(
            sessionStore: sessionStore,
            profileStore: YamiboProfileStore(defaults: defaults),
            checkInStore: YamiboCheckInStore(defaults: defaults),
            settingsStore: SettingsStore(defaults: defaults),
            webDAVSyncSettingsStore: WebDAVSyncSettingsStore(defaults: defaults),
            readerResumeRouteStore: ReaderResumeRouteStore(defaults: defaults),
            grdbRootDirectory: root.appendingPathComponent("data", isDirectory: true),
            cachesRootDirectory: root.appendingPathComponent("caches", isDirectory: true),
            uiDefaults: defaults,
            clearsWebDataOnReset: false,
            session: session,
            imageSession: session,
            httpCache: URLCache(memoryCapacity: 0, diskCapacity: 0)
        )
        try await body(context)
    }
}

private enum ChapterComposerIntegrationHTML {
    // No hidden input or token-bearing URL: only the real touch template's JS object.
    static let touchThread = """
    <html><head><title>Chapter</title></head><body>
      <div id="post_456">
        <div class="authi">
          <a class="author" href="home.php?mod=space&amp;uid=42&amp;mobile=2">南枝</a>
        </div>
        <div class="message" id="postmessage_456">Chapter body</div>
      </div>
      <div class="pg"><strong>9</strong></div>
      <script>$.ajax({data:{'favoritesubmit':'true','formhash':'a1b2c3d4'}})</script>
    </body></html>
    """

    static let rateOptions = """
    <root><![CDATA[
      <select id="rate1"><option value="1">1</option><option value="5">5</option></select>
      <select id="reason"><option value="Great chapter">Great chapter</option></select>
    ]]></root>
    """

    static let replyForm = """
    <html><head><title>Reply</title></head><body>
      <form id="postform" method="post" action="forum.php?mod=post&amp;action=reply&amp;tid=123&amp;replysubmit=yes">
        <input type="hidden" name="formhash" value="reply-token">
        <textarea name="message" required>[quote]Chapter[/quote]</textarea>
        <button type="submit" name="replysubmit" value="true">Reply</button>
      </form>
    </body></html>
    """

    static let loginPage = """
    <html><head><title>Login</title></head><body class="pg_logging">
      <form id="loginform" action="member.php?mod=logging&amp;action=login" method="post">
        <input name="username"><input type="password" name="password">
        <button type="submit">Login</button>
      </form>
    </body></html>
    """
}

private final class ChapterComposerIntegrationRequestRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var findPostHTML: String?
    private var submissionAccepted: Bool?
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recordedRequests } }

    func configure(findPostHTML: String, submissionAccepted: Bool?) {
        lock.withLock {
            self.findPostHTML = findPostHTML
            self.submissionAccepted = submissionAccepted
            recordedRequests = []
        }
    }

    func reset() {
        lock.withLock {
            findPostHTML = nil
            submissionAccepted = nil
            recordedRequests = []
        }
    }

    func responseBody(for request: URLRequest) -> String? {
        lock.withLock {
            recordedRequests.append(request)
            guard let url = request.url,
                  url.host == YamiboDomain.baseURL.host, url.path == "/forum.php" else { return nil }
            if request.httpMethod == "POST", let submissionAccepted {
                if !submissionAccepted {
                    return "<root><![CDATA[<div id=\"messagetext\"><p>抱歉，您没有权限</p></div>]]></root>"
                }
                if url.queryItemValue("ratesubmit") == "yes" {
                    return "<root><![CDATA[<div id=\"messagetext\"><p>评分成功</p></div><script>succeedhandle_rate();</script>]]></root>"
                }
                if url.queryItemValue("commentsubmit") == "yes" {
                    return "<root><![CDATA[<div id=\"messagetext\"><p>点评成功</p></div><script>succeedhandle_comment();</script>]]></root>"
                }
                return nil
            }
            guard request.httpMethod == "GET" else { return nil }
            switch (url.queryItemValue("mod"), url.queryItemValue("action")) {
            case ("redirect", _) where url.queryItemValue("goto") == "findpost":
                return findPostHTML
            case ("misc", "rate"):
                return ChapterComposerIntegrationHTML.rateOptions
            case ("post", "reply"):
                return ChapterComposerIntegrationHTML.replyForm
            default:
                return nil
            }
        }
    }
}

private final class ChapterComposerIntegrationURLProtocol: URLProtocol {
    static let record = ChapterComposerIntegrationRequestRecord()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let body = Self.record.responseBody(for: request), let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

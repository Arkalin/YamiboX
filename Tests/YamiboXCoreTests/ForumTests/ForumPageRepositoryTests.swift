import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

private extension ForumPageLoadResult {
    var page: ForumPageDocument? {
        if case let .page(page) = self { return page }
        return nil
    }
}

@Suite(.serialized) struct ForumPageRepositoryTests {
    private let url = URL(string: "https://bbs.yamibo.com/home.php?mod=spacecp&ac=profile")!

    @Test func readOnlyLoadUsesCredentialsAndNeverSubmits() async throws {
        PageDocumentURLProtocol.configure()
        let response = try await repository().fetchPage(url: url)
        let page = try #require(response.page)
        #expect(page.title == "Fixture")
        let request = try #require(PageDocumentURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("native-test") == true)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func actionLinksAndExternalURLsAreBlockedBeforeNetworking() async throws {
        PageDocumentURLProtocol.configure()
        let repo = repository()
        await #expect(throws: ForumPageError.confirmationRequired) {
            try await repo.fetchPage(url: URL(string: "https://bbs.yamibo.com/home.php?formhash=fixture&ac=friend&op=ignore")!)
        }
        await #expect(throws: ForumPageError.invalidURL) {
            try await repo.fetchPage(url: URL(string: "https://example.com/forum.php")!)
        }
        #expect(PageDocumentURLProtocol.requests.isEmpty)
    }

    @Test func unknownHTMLUsesWebFallbackInsteadOfExtractingMenus() async throws {
        PageDocumentURLProtocol.configure(html: "<nav>只看楼主 倒序浏览 返回首页 电脑版</nav>")
        #expect(try await repository().fetchPage(url: url) == .webFallback(url))
        #expect(PageDocumentURLProtocol.requests.count == 1)
    }

    @Test func knownGETDestinationIsHandedToNativeRouting() async throws {
        PageDocumentURLProtocol.configure()
        let thread = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
        #expect(try await repository().fetchPage(url: thread) == .nativeRedirect(thread))
    }

    @Test func ambiguousPOSTKeepsAnUnconfirmedStatusWithoutReplaying() async throws {
        PageDocumentURLProtocol.configure(html: "<p>Arbitrary page</p>")
        let form = ForumForm(id: "f", title: "Save", actionURL: url,
                             hiddenValues: [.init(name: "formhash", value: "fixture")], buttons: [.init(id: "b", title: "Save")])
        let response = try await repository().submit(form: form, values: [:], buttonID: "b", referer: url)
        #expect(try #require(response.page).submissionAccepted == false)
        #expect(PageDocumentURLProtocol.requests.count == 1)
    }

    @Test func explicitPostPreservesTokensAndRepeatedControls() async throws {
        PageDocumentURLProtocol.configure(html: "<div id='messagetext'>保存成功</div>")
        let form = ForumForm(id: "form", title: "Save", actionURL: url,
                                   hiddenValues: [.init(name: "formhash", value: "fixture-token"), .init(name: "items[]", value: "a"), .init(name: "items[]", value: "b")],
                                   buttons: [.init(id: "save", title: "Save", values: [.init(name: "profilesubmit", value: "true")])])
        let response = try await repository().submit(form: form, values: [:], buttonID: "save", referer: url)
        let page = try #require(response.page)
        #expect(page.submissionAccepted)
        let request = try #require(PageDocumentURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Referer") == url.absoluteString)
        #expect(PageDocumentURLProtocol.bodies.first == "formhash=fixture-token&items%5B%5D=a&items%5B%5D=b&profilesubmit=true")
        #expect(PageDocumentURLProtocol.requests.count == 1)
    }

    @Test func missingCSRFDoesNotSendAnything() async throws {
        PageDocumentURLProtocol.configure()
        let form = ForumForm(id: "f", title: "Save", actionURL: url, buttons: [.init(id: "b", title: "Save")])
        await #expect(throws: ForumPageError.invalidForm) {
            try await repository().submit(form: form, values: [:], buttonID: "b", referer: url)
        }
        #expect(PageDocumentURLProtocol.requests.isEmpty)
    }

    @Test func getFormsReplaceQueryAndRemainGET() async throws {
        PageDocumentURLProtocol.configure()
        let form = ForumForm(id: "f", title: "Search", actionURL: url, method: "GET",
                                   hiddenValues: [.init(name: "mod", value: "space"), .init(name: "username", value: "a&b")],
                                   buttons: [.init(id: "b", title: "Search")])
        _ = try await repository().submit(form: form, values: [:], buttonID: "b", referer: url)
        let request = try #require(PageDocumentURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [.init(name: "mod", value: "space"), .init(name: "username", value: "a&b")])
    }

    @Test func loginAndHTTPFailuresAreNotSuccessfulSubmissions() async throws {
        PageDocumentURLProtocol.configure(html: "<body class='pg_logging'>Login</body>")
        await #expect { try await repository().fetchPage(url: url) } throws: {
            LoadDiagnosticError.classificationError($0) as? YamiboError == .notAuthenticated
        }
        PageDocumentURLProtocol.configure(status: 500)
        await #expect { try await repository().fetchPage(url: url) } throws: {
            LoadDiagnosticError.classificationError($0) as? YamiboError == .invalidResponse(statusCode: 500)
        }
    }

    @Test func binaryAttachmentBecomesNativeFile() async throws {
        PageDocumentURLProtocol.configure(html: "%PDF-fixture", headers: ["Content-Type": "application/pdf", "Content-Disposition": "attachment; filename=sample.pdf"])
        let response = try await repository().fetchPage(url: url)
        let page = try #require(response.page)
        #expect(page.file?.name == "sample.pdf")
        #expect(page.file?.data == Data("%PDF-fixture".utf8))
    }

    @Test func blockedRedirectIsAnExplicitLinkNotAnAutomaticRequest() async throws {
        PageDocumentURLProtocol.configure(status: 302, headers: ["Location": "https://example.com/download.pdf"])
        let response = try await repository().fetchPage(url: url)
        let page = try #require(response.page)
        #expect(page.continuationURL == URL(string: "https://example.com/download.pdf"))
        #expect(PageDocumentURLProtocol.requests.count == 1)
        #expect(!page.submissionAccepted)
    }

    @Test func postIsNotReplayedAfterWAFRecovery() async throws {
        PageDocumentURLProtocol.configure(html: "challenge", status: 405, headers: ["Server": "BAIDU_WAF"])
        let recovery = PageDocumentWAFRecoverySpy()
        let form = ForumForm(id: "f", title: "Save", actionURL: url,
                                   hiddenValues: [.init(name: "formhash", value: "fixture")], buttons: [.init(id: "b", title: "Save")])
        await #expect { try await repository(recoverer: recovery).submit(form: form, values: [:], buttonID: "b", referer: url) } throws: {
            LoadDiagnosticError.classificationError($0) as? YamiboError == .securityVerificationRequired
        }
        #expect(await recovery.count == 1)
        #expect(PageDocumentURLProtocol.requests.count == 1)
    }

    @Test func uploadUsesMultipartAndMapsAttachmentWithoutPublishing() async throws {
        PageDocumentURLProtocol.configure(html: "321", headers: ["Content-Type": "text/plain"])
        let configuration = ForumUploadConfiguration(id: "u", url: URL(string: "https://bbs.yamibo.com/misc.php?mod=swfupload&operation=upload")!, kind: .threadAttachment,
                                                           values: [.init(name: "hash", value: "fixture")], maximumBytes: 1024, extensions: ["txt"])
        let result = try await repository().upload(file: .init(name: "a.txt", data: Data("fixture".utf8)), mimeType: "text/plain", configuration: configuration, referer: url)
        #expect(result.markup == "[attach]321[/attach]")
        #expect(PageDocumentURLProtocol.requests.count == 1)
        #expect(PageDocumentURLProtocol.requests[0].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        #expect(PageDocumentURLProtocol.bodies[0].contains("name=\"Filedata\"; filename=\"a.txt\""))
        #expect(!PageDocumentURLProtocol.bodies[0].contains("topicsubmit"))
    }

    @Test func mobileImageAndAttachmentUploadUseTheirOwnEndpointsWithoutPostingReply() async throws {
        let page = try ForumFormPageParser.parse(html: ForumMobileComposerFixture.html, url: ForumMobileComposerFixture.url)
        try #require(page.uploads.count == 2)
        for configuration in page.uploads {
            let isImage = configuration.kind == .threadImage
            let fileName = isImage ? "fixture.jpg" : "fixture.txt"
            PageDocumentURLProtocol.configure(html: "DISCUZUPLOAD|\(isImage ? 1 : 0)|0|321|\(isImage ? 1 : 0)||\(fileName)|0", headers: ["Content-Type": "text/plain"])
            let result = try await repository().upload(
                file: .init(name: fileName, data: Data("fixture".utf8)), mimeType: isImage ? "image/jpeg" : "text/plain",
                configuration: configuration, referer: ForumMobileComposerFixture.url
            )
            let request = try #require(PageDocumentURLProtocol.requests.first)
            let body = try #require(PageDocumentURLProtocol.bodies.first)
            #expect(PageDocumentURLProtocol.requests.count == 1)
            #expect(request.httpMethod == "POST")
            #expect(request.url == configuration.url)
            #expect(request.url?.path == "/misc.php")
            #expect(body.contains("name=\"Filedata\"; filename=\"\(fileName)\""))
            #expect(body.contains("fixture-mobile-hash"))
            #expect(!body.contains("replysubmit"))
            #expect(result.markup == (isImage ? "[attachimg]321[/attachimg]" : "[attach]321[/attach]"))
        }
    }

    private func repository(recoverer: (any YamiboWAFChallengeRecovering)? = nil) -> ForumPageRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PageDocumentURLProtocol.self]
        configuration.httpCookieStorage = nil
        return ForumPageRepository(client: YamiboClient(session: URLSession(configuration: configuration), cookie: "\(SessionState.authenticationCookieName)=native-test", wafRecoverer: recoverer))
    }
}

private actor PageDocumentWAFRecoverySpy: YamiboWAFChallengeRecovering {
    private(set) var count = 0
    func recover(from challenge: YamiboWAFChallenge) -> YamiboRequestCredentials {
        count += 1
        return .init(cookies: [], userAgent: "Native-Test-UA")
    }
    func presentFallback(for challenge: YamiboWAFChallenge) {}
}

private final class PageDocumentURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var payload = ""
    private nonisolated(unsafe) static var status = 200
    private nonisolated(unsafe) static var headers: [String: String] = [:]
    private nonisolated(unsafe) static var recorded: [URLRequest] = []
    private nonisolated(unsafe) static var recordedBodies: [String] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var bodies: [String] { lock.withLock { recordedBodies } }

    static func configure(html: String = "<title>Fixture</title><div id='messagetext'>Explicit status</div>", status: Int = 200, headers: [String: String] = [:]) {
        lock.withLock {
            payload = html
            self.status = status
            self.headers = headers
            recorded = []
            recordedBodies = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let response = Self.lock.withLock {
            Self.recorded.append(request)
            Self.recordedBodies.append(String(decoding: data, as: UTF8.self))
            return (Self.payload, Self.status, Self.headers)
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.1, httpVersion: nil, headerFields: response.2)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.0.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

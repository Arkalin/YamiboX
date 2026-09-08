import Foundation
import Testing
@testable import YamiboXCore

@Suite("Message unread repository", .serialized)
struct MessageUnreadRepositoryTests {
    @Test func probesOnlyFirstPrivateMessagePageWithCurrentCredentialsAndNoCache() async throws {
        UnreadRepositoryURLProtocol.configure(body: Self.html)
        defer { UnreadRepositoryURLProtocol.reset() }
        let repository = makeRepository()
        let summary = try await repository.fetchUnreadSummary()
        #expect(summary == MessageUnreadSummary(privateMessageCount: 4, noticeCount: 6))
        let requests = UnreadRepositoryURLProtocol.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let url = try #require(request.url)
        #expect(url == YamiboRoute.userSpacePrivateMessages(page: 1).url)
        #expect(request.httpMethod == "GET")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "\(SessionState.authenticationCookieName)=unread-test")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Unread-Test-UA")
    }

    @Test func wafFailureNeverRecoversOrPresentsVerification() async throws {
        UnreadRepositoryURLProtocol.configure(body: "challenge", status: 405, headers: ["Server": "BAIDU_WAF"])
        defer { UnreadRepositoryURLProtocol.reset() }
        let recovery = UnreadWAFRecoverySpy()
        let repository = makeRepository(recoverer: recovery)
        await #expect {
            try await repository.fetchUnreadSummary()
        } throws: { error in
            (LoadDiagnosticError.classificationError(error) as? YamiboError) == .securityVerificationRequired
        }
        #expect(await recovery.recoveryCount == 0)
        #expect(await recovery.presentationCount == 0)
        #expect(UnreadRepositoryURLProtocol.requests().count == 1)
    }

    @Test func loginResponseIsNotMistakenForZeroUnread() async throws {
        UnreadRepositoryURLProtocol.configure(body: "<html><body class='pg_logging'>Login</body></html>")
        defer { UnreadRepositoryURLProtocol.reset() }
        await #expect {
            try await makeRepository().fetchUnreadSummary()
        } throws: { error in
            (LoadDiagnosticError.classificationError(error) as? YamiboError) == .notAuthenticated
        }
    }

    private func makeRepository(recoverer: (any YamiboWAFChallengeRecovering)? = nil) -> UserSpaceRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnreadRepositoryURLProtocol.self]
        configuration.httpCookieStorage = nil
        return UserSpaceRepository(client: YamiboClient(
            session: URLSession(configuration: configuration),
            cookie: "\(SessionState.authenticationCookieName)=unread-test",
            userAgent: "Unread-Test-UA",
            wafRecoverer: recoverer
        ))
    }

    private static let html = """
    <div class="dhnv">
      <a href="home.php?mod=space&amp;do=pm">PM<strong>(4)</strong></a>
      <a href="home.php?mod=space&amp;do=notice">Notice<strong>(6)</strong></a>
    </div>
    """
}

private final class UnreadRepositoryURLProtocol: URLProtocol {
    private struct Response {
        var body: String
        var status: Int
        var headers: [String: String]
    }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var response: Response?
    private nonisolated(unsafe) static var recorded: [URLRequest] = []

    static func configure(body: String, status: Int = 200, headers: [String: String] = [:]) {
        lock.withLock {
            response = Response(body: body, status: status, headers: headers)
            recorded = []
        }
    }

    static func reset() { lock.withLock { response = nil; recorded = [] } }
    static func requests() -> [URLRequest] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.response
        }
        guard let response, let url = request.url,
              let httpResponse = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor UnreadWAFRecoverySpy: YamiboWAFChallengeRecovering {
    private(set) var recoveryCount = 0
    private(set) var presentationCount = 0
    func recover(from challenge: YamiboWAFChallenge) async throws -> YamiboRequestCredentials {
        recoveryCount += 1
        throw YamiboError.securityVerificationRequired
    }
    func presentFallback(for challenge: YamiboWAFChallenge) { presentationCount += 1 }
}

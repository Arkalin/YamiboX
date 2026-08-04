import Foundation
import Testing
@testable import YamiboXCore

@Suite("Yamibo WAF", .serialized)
private struct YamiboWAFTests {
    @Test func detectorRecognizesTrustedWAFSignalsOnlyForYamibo405Responses() throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php"))
        let wafResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 405,
            httpVersion: nil,
            headerFields: ["Server": "BAIDU_WAF/1.0"]
        ))
        #expect(YamiboWAFResponseDetector.matches(data: Data(), response: wafResponse, requestURL: url))

        let markerResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 405,
            httpVersion: nil,
            headerFields: [:]
        ))
        #expect(YamiboWAFResponseDetector.matches(
            data: Data("<script>window.__noxExpire=1; var token='nox_jst_v1'</script>".utf8),
            response: markerResponse,
            requestURL: url
        ))
        #expect(!YamiboWAFResponseDetector.matches(
            data: Data("nox_jst_v1".utf8),
            response: markerResponse,
            requestURL: url
        ))

        let successfulResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Server": "BAIDU_WAF"]
        ))
        #expect(!YamiboWAFResponseDetector.matches(data: Data(), response: successfulResponse, requestURL: url))

        let externalURL = try #require(URL(string: "https://example.com/forum.php"))
        let externalResponse = try #require(HTTPURLResponse(
            url: externalURL,
            statusCode: 405,
            httpVersion: nil,
            headerFields: ["bdwaf-request-id": "request"]
        ))
        #expect(!YamiboWAFResponseDetector.matches(data: Data(), response: externalResponse, requestURL: externalURL))
    }

    @Test func legacySessionMigrationDropsUndatedWAFCookiesButKeepsAuthentication() throws {
        let data = Data(#"{"cookie":"sid=one; nox_jst_v1=stale; EeqY_2132_auth=member","isLoggedIn":true}"#.utf8)
        let session = try JSONDecoder().decode(SessionState.self, from: data)

        #expect(session.cookies.contains { $0.name == "sid" && $0.value == "one" })
        #expect(session.cookies.contains { $0.name == SessionState.authenticationCookieName && $0.value == "member" })
        #expect(!session.cookies.contains { $0.name == "nox_jst_v1" })
    }

    @Test func cookieHeaderFiltersExpirySecurityDomainAndPathInStableOrder() throws {
        let now = Date.now
        let credentials = YamiboRequestCredentials(cookies: [
            YamiboCookie(name: "root", value: "1", domain: ".yamibo.com", expiresAt: now.addingTimeInterval(60)),
            YamiboCookie(name: "deep", value: "2", domain: YamiboDomain.forumHost, path: "/forum", expiresAt: now.addingTimeInterval(60)),
            YamiboCookie(name: "expired", value: "3", domain: YamiboDomain.forumHost, expiresAt: now.addingTimeInterval(-1)),
            YamiboCookie(name: "secure", value: "4", domain: YamiboDomain.forumHost, expiresAt: now.addingTimeInterval(60)),
            YamiboCookie(name: "other", value: "5", domain: "files.yamibo.com", expiresAt: now.addingTimeInterval(60))
        ], userAgent: "UnitAgent")
        let forumURL = try #require(URL(string: "https://bbs.yamibo.com/forum/thread.php"))
        let insecureURL = try #require(URL(string: "http://bbs.yamibo.com/forum/thread.php"))

        #expect(credentials.cookieHeader(for: forumURL) == "deep=2; root=1; secure=4")
        #expect(credentials.cookieHeader(for: insecureURL).isEmpty)
    }

    @Test func webCookieSnapshotKeepsCurrentAuthenticationAndAccountWhenOnlyClearanceChanges() async throws {
        let suiteName = "YamiboWAFTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SessionStore(defaults: defaults, key: "session")
        let now = Date.now
        let auth = YamiboCookie(
            name: SessionState.authenticationCookieName,
            value: "member",
            domain: YamiboDomain.forumHost,
            expiresAt: now.addingTimeInterval(3_600),
            capturedAt: now
        )
        try await store.save(SessionState(
            cookies: [auth],
            userAgent: "UnitAgent",
            isLoggedIn: true,
            accountUID: "42"
        ))
        let clearance = YamiboCookie(
            name: "nox_jst_v1",
            value: "fresh",
            domain: YamiboDomain.forumHost,
            expiresAt: now.addingTimeInterval(600),
            capturedAt: now.addingTimeInterval(1)
        )

        try await store.updateWebSession(cookies: [clearance], userAgent: "UnitAgent")
        let saved = await store.load()

        #expect(saved.authenticationCookie?.value == "member")
        #expect(saved.accountUID == "42")
        #expect(saved.cookies.contains { $0.name == "nox_jst_v1" && $0.value == "fresh" })
    }

    @Test func clientRetriesOnceWithRecoveredCookieAndPreservesPostBody() async throws {
        YamiboWAFTestURLProtocol.setResponses([
            .init(statusCode: 405, headers: ["Server": "BAIDU_WAF"], body: "challenge"),
            .init(statusCode: 200, headers: [:], body: "<html>recovered</html>")
        ])
        defer { YamiboWAFTestURLProtocol.reset() }
        let recoverer = YamiboWAFTestRecoverer()
        let client = YamiboClient(
            session: makeYamiboWAFTestSession(),
            credentials: YamiboRequestCredentials(cookies: [], userAgent: "UnitAgent"),
            wafRecoverer: recoverer
        )
        let url = try #require(URL(string: "https://bbs.yamibo.com/plugin.php?id=check"))

        let html = try await client.submitForm(url: url, fields: [("action", "check in"), ("token", "abc")])
        let requests = YamiboWAFTestURLProtocol.requests()

        #expect(html.contains("recovered"))
        #expect(await recoverer.recoveryCount == 1)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(requests[0].httpBody == requests[1].httpBody)
        #expect(requests[1].value(forHTTPHeaderField: "Cookie")?.contains("nox_jst_v1=fresh") == true)
    }

    @Test func secondWAFResponsePresentsFallbackAndDoesNotIssueThirdRequest() async throws {
        YamiboWAFTestURLProtocol.setResponses([
            .init(statusCode: 405, headers: ["bdwaf-request-id": "one"], body: "challenge"),
            .init(statusCode: 405, headers: ["bdwaf-request-id": "two"], body: "challenge")
        ])
        defer { YamiboWAFTestURLProtocol.reset() }
        let recoverer = YamiboWAFTestRecoverer()
        let client = YamiboClient(
            session: makeYamiboWAFTestSession(),
            credentials: YamiboRequestCredentials(cookies: [], userAgent: "UnitAgent"),
            wafRecoverer: recoverer
        )
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php"))

        await #expect(throws: YamiboError.securityVerificationRequired) {
            try await client.fetchHTML(url: url)
        }

        #expect(await recoverer.recoveryCount == 1)
        #expect(await recoverer.fallbackCount == 1)
        #expect(YamiboWAFTestURLProtocol.requests().count == 2)
    }
}

private actor YamiboWAFTestRecoverer: YamiboWAFChallengeRecovering {
    private(set) var recoveryCount = 0
    private(set) var fallbackCount = 0

    func recover(from challenge: YamiboWAFChallenge) async throws -> YamiboRequestCredentials {
        recoveryCount += 1
        return YamiboRequestCredentials(
            cookies: [YamiboCookie(
                name: "nox_jst_v1",
                value: "fresh",
                domain: YamiboDomain.forumHost,
                expiresAt: .now.addingTimeInterval(600)
            )],
            userAgent: challenge.userAgent
        )
    }

    func presentFallback(for _: YamiboWAFChallenge) async {
        fallbackCount += 1
    }
}

private final class YamiboWAFTestURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: String
    }

    private nonisolated(unsafe) static var responses: [Response] = []
    private nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func setResponses(_ responses: [Response]) {
        lock.lock()
        self.responses = responses
        recordedRequests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responses = []
        recordedRequests = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let response = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        Self.lock.unlock()

        guard let response, let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeYamiboWAFTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [YamiboWAFTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

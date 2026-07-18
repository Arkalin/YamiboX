import Foundation
import Testing
@testable import YamiboXCore

private struct YamiboCheckInStubResponse {
    let statusCode: Int
    let body: String
}

private enum YamiboCheckInStubOutput {
    case response(YamiboCheckInStubResponse)
    case error(Error)
}

private final class YamiboCheckInURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var handlers: [String: (URLRequest) -> YamiboCheckInStubOutput] = [:]
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func setHandler(_ handler: @escaping (URLRequest) -> YamiboCheckInStubOutput, for testID: String) {
        lock.lock()
        handlers[testID] = handler
        lock.unlock()
    }

    static func removeHandler(for testID: String) {
        lock.lock()
        handlers.removeValue(forKey: testID)
        lock.unlock()
    }

    override func startLoading() {
        let testID = request.value(forHTTPHeaderField: "X-YamiboCheckIn-Test-ID") ?? ""
        Self.lock.lock()
        let handler = Self.handlers[testID]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch handler(request) {
        case let .response(output):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: output.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(output.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Test func yamiboCheckInReturnsNotAuthenticatedWhenSessionIsMissing() async throws {
    let testID = UUID().uuidString
    let suiteName = makeYamiboCheckInSuiteName(prefix: "not-auth")
    let sessionStore = SessionStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), key: "session")
    let checkInStore = YamiboCheckInStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), keyPrefix: "check-in")
    let service = YamiboCheckInService(
        sessionStore: sessionStore,
        checkInStore: checkInStore,
        session: makeYamiboCheckInSession(testID: testID),
        verificationDelayNanoseconds: 0
    )

    let result = await service.checkInIfNeeded()

    #expect(result == .notAuthenticated)
}

@Test func yamiboCheckInRecognizesAlreadyCheckedInPageAndPersistsToday() async throws {
    let testID = UUID().uuidString
    let suiteName = makeYamiboCheckInSuiteName(prefix: "already-checked-in")
    let sessionStore = SessionStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), key: "session")
    let checkInStore = YamiboCheckInStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), keyPrefix: "check-in")
    try await sessionStore.save(
        SessionState(
            cookie: "foo=1; EeqY_2132_auth=user-a",
            userAgent: "Test-UA",
            isLoggedIn: true
        )
    )

    YamiboCheckInURLProtocol.setHandler({ request in
        #expect(request.value(forHTTPHeaderField: "Cookie") == "foo=1; EeqY_2132_auth=user-a")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Test-UA")
        return .response(
            YamiboCheckInStubResponse(
                statusCode: 200,
                body: #"<div class="signbtn"><a href="javascript:;" class="btna">今日已打卡</a></div><table><tbody id="tablebody"><tr><td class="day today on">18</td></tr></tbody></table>"#
            )
        )
    }, for: testID)
    defer { YamiboCheckInURLProtocol.removeHandler(for: testID) }

    let service = YamiboCheckInService(
        sessionStore: sessionStore,
        checkInStore: checkInStore,
        session: makeYamiboCheckInSession(testID: testID),
        verificationDelayNanoseconds: 0
    )

    let result = await service.checkInIfNeeded(force: true)

    #expect(result == .alreadyCheckedInToday)
    let lastCheckedInDate = await checkInStore.lastCheckedInDate(
        session: SessionState(cookie: "foo=1; EeqY_2132_auth=user-a", userAgent: "Test-UA", isLoggedIn: true)
    )
    #expect(lastCheckedInDate != nil)
}

@Test func yamiboCheckInRequestsCheckInURLAndSucceedsAfterVerification() async throws {
    let testID = UUID().uuidString
    let suiteName = makeYamiboCheckInSuiteName(prefix: "check-in-success")
    let sessionStore = SessionStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), key: "session")
    let checkInStore = YamiboCheckInStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), keyPrefix: "check-in")
    let sessionState = SessionState(
        cookie: "sid=1; EeqY_2132_auth=user-b",
        userAgent: "Test-UA",
        isLoggedIn: true
    )
    try await sessionStore.save(sessionState)

    let lock = NSLock()
    var checkInPageVisits = 0
    var requestedURLs: [String] = []

    YamiboCheckInURLProtocol.setHandler({ request in
        lock.lock()
        requestedURLs.append(request.url!.absoluteString)
        let currentVisit = checkInPageVisits
        if request.url == YamiboCheckInService.checkInPageURL {
            checkInPageVisits += 1
        }
        lock.unlock()

        if request.url == YamiboCheckInService.checkInPageURL, currentVisit == 0 {
            return .response(
                YamiboCheckInStubResponse(
                    statusCode: 200,
                    body: #"<div class="signbtn"><a href="plugin.php?id=zqlj_sign&amp;sign=abc123" class="btna">点击打卡</a></div><table><tbody id="tablebody"><tr><td class="day today">18</td></tr></tbody></table>"#
                )
            )
        }

        if request.url?.absoluteString == "https://bbs.yamibo.com/plugin.php?id=zqlj_sign&sign=abc123" {
            return .response(YamiboCheckInStubResponse(statusCode: 200, body: "<html>ok</html>"))
        }

        return .response(
            YamiboCheckInStubResponse(
                statusCode: 200,
                body: #"<div class="signbtn"><a href="javascript:;" class="btna">今日已打卡</a></div><table><tbody id="tablebody"><tr><td class="day today on">18</td></tr></tbody></table>"#
            )
        )
    }, for: testID)
    defer { YamiboCheckInURLProtocol.removeHandler(for: testID) }

    let service = YamiboCheckInService(
        sessionStore: sessionStore,
        checkInStore: checkInStore,
        session: makeYamiboCheckInSession(testID: testID),
        verificationDelayNanoseconds: 0
    )

    let result = await service.checkInIfNeeded(force: true)

    #expect(result == .success)
    #expect(requestedURLs == [
        "https://bbs.yamibo.com/plugin.php?id=zqlj_sign&mobile=2",
        "https://bbs.yamibo.com/plugin.php?id=zqlj_sign&sign=abc123",
        "https://bbs.yamibo.com/plugin.php?id=zqlj_sign&mobile=2"
    ])
    let needsCheckIn = await checkInStore.needsCheckIn(session: sessionState)
    #expect(needsCheckIn == false)
}

@Test func yamiboCheckInSkipsNetworkWhenTodayIsAlreadyRecorded() async throws {
    let testID = UUID().uuidString
    let suiteName = makeYamiboCheckInSuiteName(prefix: "skip-today")
    let sessionStore = SessionStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), key: "session")
    let checkInStore = YamiboCheckInStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), keyPrefix: "check-in")
    let sessionState = SessionState(
        cookie: "sid=1; EeqY_2132_auth=user-c",
        userAgent: "Test-UA",
        isLoggedIn: true
    )
    try await sessionStore.save(sessionState)
    await checkInStore.markCheckedIn(session: sessionState)

    let lock = NSLock()
    var requestCount = 0
    YamiboCheckInURLProtocol.setHandler({ _ in
        lock.lock()
        requestCount += 1
        lock.unlock()
        return .error(URLError(.badServerResponse))
    }, for: testID)
    defer { YamiboCheckInURLProtocol.removeHandler(for: testID) }

    let service = YamiboCheckInService(
        sessionStore: sessionStore,
        checkInStore: checkInStore,
        session: makeYamiboCheckInSession(testID: testID),
        verificationDelayNanoseconds: 0
    )

    let result = await service.checkInIfNeeded()

    #expect(result == .skippedToday)
    #expect(requestCount == 0)
}

@Test func yamiboCheckInReturnsParseFailedWhenCheckInLinkIsMissing() async throws {
    let testID = UUID().uuidString
    let suiteName = makeYamiboCheckInSuiteName(prefix: "parse-failed")
    let sessionStore = SessionStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), key: "session")
    let checkInStore = YamiboCheckInStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), keyPrefix: "check-in")
    try await sessionStore.save(
        SessionState(
            cookie: "sid=1; EeqY_2132_auth=user-d",
            userAgent: "Test-UA",
            isLoggedIn: true
        )
    )

    YamiboCheckInURLProtocol.setHandler({ _ in
        .response(
            YamiboCheckInStubResponse(
                statusCode: 200,
                body: #"<div class="signbtn"><a href="javascript:;" class="btna">点击打卡</a></div><table><tbody id="tablebody"><tr><td class="day today">18</td></tr></tbody></table>"#
            )
        )
    }, for: testID)
    defer { YamiboCheckInURLProtocol.removeHandler(for: testID) }

    let service = YamiboCheckInService(
        sessionStore: sessionStore,
        checkInStore: checkInStore,
        session: makeYamiboCheckInSession(testID: testID),
        verificationDelayNanoseconds: 0
    )

    let result = await service.checkInIfNeeded(force: true)

    #expect(result == .parseFailed)
}

@Test func yamiboCheckInReturnsVerificationFailedWhenServerDoesNotConfirmCheckIn() async throws {
    let testID = UUID().uuidString
    let suiteName = makeYamiboCheckInSuiteName(prefix: "verify-failed")
    let sessionStore = SessionStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), key: "session")
    let checkInStore = YamiboCheckInStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), keyPrefix: "check-in")
    try await sessionStore.save(
        SessionState(
            cookie: "sid=1; EeqY_2132_auth=user-e",
            userAgent: "Test-UA",
            isLoggedIn: true
        )
    )

    let lock = NSLock()
    var checkInPageVisits = 0

    YamiboCheckInURLProtocol.setHandler({ request in
        if request.url == YamiboCheckInService.checkInPageURL {
            lock.lock()
            let currentVisit = checkInPageVisits
            checkInPageVisits += 1
            lock.unlock()

            if currentVisit == 0 {
                return .response(
                    YamiboCheckInStubResponse(
                        statusCode: 200,
                        body: #"<div class="signbtn"><a href="plugin.php?id=zqlj_sign&amp;sign=late" class="btna">点击打卡</a></div><table><tbody id="tablebody"><tr><td class="day today">18</td></tr></tbody></table>"#
                    )
                )
            }
            return .response(
                YamiboCheckInStubResponse(
                    statusCode: 200,
                    body: #"<div class="signbtn"><a href="plugin.php?id=zqlj_sign&amp;sign=late" class="btna">点击打卡</a></div><table><tbody id="tablebody"><tr><td class="day today">18</td></tr></tbody></table>"#
                )
            )
        }

        return .response(YamiboCheckInStubResponse(statusCode: 200, body: "<html>ok</html>"))
    }, for: testID)
    defer { YamiboCheckInURLProtocol.removeHandler(for: testID) }

    let service = YamiboCheckInService(
        sessionStore: sessionStore,
        checkInStore: checkInStore,
        session: makeYamiboCheckInSession(testID: testID),
        verificationDelayNanoseconds: 0
    )

    let result = await service.checkInIfNeeded(force: true)

    #expect(result == .verificationFailed)
}

@Test func yamiboCheckInStoreSeparatesDifferentAccounts() async throws {
    let suiteName = makeYamiboCheckInSuiteName(prefix: "account-isolation")
    let store = YamiboCheckInStore(defaults: try makeYamiboCheckInDefaults(suiteName: suiteName), keyPrefix: "check-in")
    let first = SessionState(cookie: "foo=1; EeqY_2132_auth=alpha", isLoggedIn: true)
    let second = SessionState(cookie: "foo=1; EeqY_2132_auth=beta", isLoggedIn: true)

    await store.markCheckedIn(session: first)

    let firstDate = await store.lastCheckedInDate(session: first)
    let secondDate = await store.lastCheckedInDate(session: second)
    #expect(firstDate != nil)
    #expect(secondDate == nil)
}

private func makeYamiboCheckInSession(testID: String) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [YamiboCheckInURLProtocol.self]
    configuration.httpAdditionalHeaders = ["X-YamiboCheckIn-Test-ID": testID]
    return URLSession(configuration: configuration)
}

private func makeYamiboCheckInSuiteName(prefix: String) -> String {
    "\(prefix)-\(UUID().uuidString)"
}

private func makeYamiboCheckInDefaults(suiteName: String) throws -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw YamiboError.underlying("Failed to create UserDefaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class MineWebLoginSessionMonitorTests: XCTestCase {
    func testAuthenticatedWebSessionCompletesMonitoring() async throws {
        let suiteName = "mine-web-login-session-monitor-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sessionStore = SessionStore(defaults: defaults, key: "session")
        let monitor = MineWebLoginSessionMonitor(sessionStore: sessionStore)
        let completion = Task { await monitor.waitForAuthentication() }

        try await sessionStore.updateWebSession(
            cookie: "sid=web; EeqY_2132_auth=web-token",
            userAgent: "Web-UA",
            isLoggedIn: true
        )

        let didAuthenticate = await completion.value
        XCTAssertTrue(didAuthenticate)
    }

    func testMonitorReturnsTrueWhenAuthenticationAlreadyPresent() async throws {
        let suiteName = "mine-web-login-session-monitor-already-auth-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sessionStore = SessionStore(defaults: defaults, key: "session")
        try await sessionStore.updateWebSession(
            cookie: "sid=web; EeqY_2132_auth=web-token",
            userAgent: "Web-UA",
            isLoggedIn: true
        )

        let monitor = MineWebLoginSessionMonitor(sessionStore: sessionStore)
        let didAuthenticate = await monitor.waitForAuthentication()
        XCTAssertTrue(didAuthenticate)
    }
}

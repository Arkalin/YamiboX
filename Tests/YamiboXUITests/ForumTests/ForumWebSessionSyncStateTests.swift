import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class ForumWebSessionSyncStateTests: XCTestCase {
    func testPersistedWebSessionDoesNotReloadTheSameWebViewAgain() {
        var state = ForumWebSessionSyncState()
        let cookieHeader = "EeqY_2132_auth=token; sid=web"
        state.markPersistedWebSession(cookieHeader: cookieHeader)

        let action = state.action(
            for: SessionState(cookie: cookieHeader, isLoggedIn: true),
            reloadIfNeeded: true
        )

        XCTAssertEqual(action, .none)
    }

    func testRepeatedEmptySessionDoesNotReloadAnonymousForumView() {
        var state = ForumWebSessionSyncState()

        XCTAssertEqual(
            state.action(for: SessionState(cookie: "", isLoggedIn: false), reloadIfNeeded: true),
            .clearCookies(reload: false)
        )
        XCTAssertEqual(
            state.action(for: SessionState(cookie: "", isLoggedIn: false), reloadIfNeeded: true),
            .none
        )
    }

    func testClearingPreviouslyInjectedAuthenticationCookiesReloads() {
        var state = ForumWebSessionSyncState()
        _ = state.action(
            for: SessionState(cookie: "EeqY_2132_auth=token; sid=web", isLoggedIn: true),
            reloadIfNeeded: false
        )

        let action = state.action(
            for: SessionState(cookie: "", isLoggedIn: false),
            reloadIfNeeded: true
        )

        XCTAssertEqual(action, .clearCookies(reload: true))
    }
}

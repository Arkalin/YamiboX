import WebKit
import XCTest
import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ForumBrowserSessionBoundaryTests: XCTestCase {
    func testWebLoginRearmsFallbackAndPersistsCookiesBeforeNativeHandoff() async throws {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
        let suite = "browser-session-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = SessionStore(defaults: defaults)
        var forwarded: [URL] = []
        let model = ForumBrowserModel(initialURL: url, nativeFallback: true, onNativeNavigation: { forwarded.append($0) })
        let coordinator = IOSForumWebView.Coordinator(model: model, sessionStore: sessions)
        let webView = try await loadedWebView(url: url)
        try await setAuthenticationCookie(in: webView)
        XCTAssertFalse(model.shouldRouteNatively(url, method: "GET", isMainFrame: true))

        coordinator.webView(webView, didFinish: nil)
        for _ in 0..<100 where forwarded.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(forwarded, [url])
        let session = await sessions.load()
        XCTAssertEqual(session.authenticationCookie?.value, "fixture-auth")
        coordinator.webView(webView, didFinish: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(forwarded.count, 1)
    }

    func testAccountTransitionCancelsPendingWebAuthenticationHandoff() async throws {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
        let suite = "browser-transition-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = SessionStore(defaults: defaults)
        var forwarded: [URL] = []
        let model = ForumBrowserModel(initialURL: url, nativeFallback: true, onNativeNavigation: { forwarded.append($0) })
        let coordinator = IOSForumWebView.Coordinator(model: model, sessionStore: sessions)
        let webView = try await loadedWebView(url: url)
        try await setAuthenticationCookie(in: webView)
        coordinator.webView(webView, didFinish: nil)
        await IOSForumWebView.Coordinator.prepareForAccountChange(sessionStore: sessions)
        XCTAssertTrue(forwarded.isEmpty)
        let session = await sessions.load()
        XCTAssertNil(session.authenticationCookie)
        await IOSForumWebView.Coordinator.finishAccountChange(session, sessionStore: sessions)
    }

    private func loadedWebView(url: URL) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: configuration)
        view.loadHTMLString("<html><head><title>Offline login result</title></head><body>Result</body></html>", baseURL: url)
        for _ in 0..<200 {
            if view.url == url, !view.isLoading { return view }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Offline WebView did not finish loading")
        return view
    }

    private func setAuthenticationCookie(in view: WKWebView) async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "bbs.yamibo.com", .path: "/", .name: SessionState.authenticationCookieName,
            .value: "fixture-auth", .secure: "TRUE"
        ]))
        await withCheckedContinuation { continuation in
            view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }
}

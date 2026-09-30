import Foundation
import WebKit
import YamiboXCore

/// Owns no presentation surface and never shares the foreground verification WebView.
@MainActor
public final class BackgroundCheckInWAFRecoverer: YamiboWAFChallengeRecovering {
    private let sessionStore: SessionStore
    private let snapshot: AccountSessionSnapshot

    public init(sessionStore: SessionStore, snapshot: AccountSessionSnapshot) {
        self.sessionStore = sessionStore
        self.snapshot = snapshot
    }

    public func synchronizeCookies() async throws {
        _ = try await SilentWAFRequest(sessionStore: sessionStore, snapshot: snapshot).run(challenge: nil)
    }

    public func recover(from challenge: YamiboWAFChallenge) async throws -> YamiboRequestCredentials {
        try await SilentWAFRequest(sessionStore: sessionStore, snapshot: snapshot).run(challenge: challenge)
    }

    public func presentFallback(for challenge: YamiboWAFChallenge) async {}
}

@MainActor
private final class SilentWAFRequest: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let sessionStore: SessionStore
    private let snapshot: AccountSessionSnapshot
    private var continuation: CheckedContinuation<YamiboRequestCredentials, Error>?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var webView: WKWebView?
    private let navigationLogs = WebNavigationLogCapture(source: .webVerification)

    init(sessionStore: SessionStore, snapshot: AccountSessionSnapshot) {
        self.sessionStore = sessionStore
        self.snapshot = snapshot
    }

    func run(challenge: YamiboWAFChallenge?) async throws -> YamiboRequestCredentials {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.finish(.failure(YamiboError.securityVerificationRequired))
                }
                work = Task {
                    do { self.finish(.success(try await self.execute(challenge: challenge))) }
                    catch { self.finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func validate() async throws {
        try Task.checkCancellation()
        guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func execute(challenge: YamiboWAFChallenge?) async throws -> YamiboRequestCredentials {
        try await validate()
        let stored = await WKWebsiteDataStore.default().httpCookieStore.allCookies().map { YamiboCookie($0) }
        try await validate()
        try await sessionStore.mergeWAFCookies(stored, expectedGeneration: snapshot.generation)
        let session = try await sessionStore.snapshot().session
        try await validate()
        guard let challenge else { return session.credentials }
        if usableClearance(session.cookies, replacing: challenge) { return session.credentials }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Public WebKit policy permits JS in an unattached view while the host has runtime.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.add(self, name: "yamiboWAFInteraction")
        configuration.userContentController.addUserScript(WKUserScript(
            source: ForumWebSessionCoordinator.interactionDetectionScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view
        view.navigationDelegate = self
        view.customUserAgent = snapshot.session.userAgent
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        // A challenge never needs the forum login; do not expose it to the temporary page.
        for cookie in session.cookies where YamiboCookie.isWAFCookie(cookie.name) && !cookie.isExpired() {
            if let value = cookie.httpCookie() { await cookieStore.setCookieAsync(value) }
            try await validate()
        }
        view.load(URLRequest(url: YamiboRoute.login.url, cachePolicy: .reloadIgnoringLocalCacheData))
        while true {
            try await validate()
            let cookies = await cookieStore.allCookies().map { YamiboCookie($0) }
            try await validate()
            if usableClearance(cookies, replacing: challenge) {
                try await sessionStore.mergeWAFCookies(cookies, expectedGeneration: snapshot.generation, replacingCurrent: true)
                try await validate()
                return YamiboRequestCredentials(
                    cookies: cookies.filter { YamiboCookie.isWAFCookie($0.name) },
                    userAgent: snapshot.session.userAgent
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func usableClearance(_ cookies: [YamiboCookie], replacing challenge: YamiboWAFChallenge) -> Bool {
        cookies.contains {
            $0.name == "nox_jst_v1" && $0.matches(challenge.url)
                && ($0.expiresAt?.timeIntervalSinceNow ?? 0) > 60
                && (YamiboWAFChallenge.clearanceFingerprint(for: $0.value) != challenge.clearanceFingerprint
                    || $0.expiresAt != challenge.clearanceExpiresAt)
        }
    }

    private func finish(_ result: Result<YamiboRequestCredentials, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        work?.cancel()
        timeout = nil
        work = nil
        navigationLogs.finishAll(error: CancellationError())
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "yamiboWAFInteraction")
        webView = nil
        continuation.resume(with: result)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        finish(.failure(YamiboError.securityVerificationRequired))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationLogs.processTerminated()
        finish(.failure(YamiboError.securityVerificationRequired))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationLogs.finish(navigation, error: error)
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationLogs.finish(navigation, error: error)
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationLogs.start(navigation, webView: webView)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        navigationLogs.redirect(navigation, webView: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationLogs.finish(navigation)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationLogs.receive(navigationResponse)
        guard navigationResponse.canShowMIMEType else {
            navigationLogs.cancel(navigationResponse)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, YamiboDomain.isForumURL(url) else {
            finish(.failure(YamiboError.securityVerificationRequired))
            return .cancel
        }
        navigationLogs.allow(navigationAction)
        return .allow
    }
}

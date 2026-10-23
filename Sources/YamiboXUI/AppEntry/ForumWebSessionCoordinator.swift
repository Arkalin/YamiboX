import Observation
import SwiftUI
import WebKit
import YamiboXCore

#if os(iOS)
import UIKit

/// Explicit login browser and account lifecycle bridge. Verification runs in
/// a different, unattached WebKit instance without this browser's credentials.
@MainActor
@Observable
public final class ForumWebSessionCoordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate {
    public let recovery: ForumWAFRecoveryCoordinator
    public let requestExecutor: ForumRequestExecutor
    public let webView: WKWebView
    public private(set) var silentFailure: String?
    private let sessionStore: SessionStore
    private let cookieStore: WKHTTPCookieStore
    private var cookieSyncTask: Task<Void, Never>?
    private var preheatTask: Task<Void, Never>?
    private var lastPreheatAt: Date?
    private var webGeneration = UUID()
    private var isChangingAccount = false
    private let navigationLogs = WebNavigationLogCapture(source: .webVerification)
    private let wafBridge: ForumWebWAFBridge

    public init(sessionStore: SessionStore, websiteDataStore: WKWebsiteDataStore = .default()) {
        self.sessionStore = sessionStore
        let recovery = ForumWAFRecoveryCoordinator(verifier: WebKitSilentForumVerifier())
        self.recovery = recovery
        requestExecutor = ForumRequestExecutor(recovery: recovery)
        wafBridge = ForumWebWAFBridge(sessionStore: sessionStore, executor: requestExecutor)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        cookieStore = configuration.websiteDataStore.httpCookieStore
        super.init()
        wafBridge.onFailure = { [weak self] in self?.silentFailure = $0.localizedDescription }
        webView.navigationDelegate = self
        cookieStore.add(self)
    }

    public func setAppIsActive(_ active: Bool) {
        if !active {
            preheatTask?.cancel()
            preheatTask = nil
            return
        }
        guard !isChangingAccount, preheatTask == nil,
              lastPreheatAt.map({ Date.now.timeIntervalSince($0) >= 600 }) != false else { return }
        lastPreheatAt = .now
        preheatTask = Task { [weak self] in
            guard let self else { return }
            defer { preheatTask = nil }
            guard let snapshot = try? await sessionStore.snapshot(), snapshot.session.isLoggedIn else { return }
            let clearance = snapshot.session.cookies.first { $0.name == "nox_jst_v1" && $0.matches(YamiboDomain.baseURL) }
            guard (clearance?.expiresAt?.timeIntervalSinceNow ?? 0) <= 300 else { return }
            let challenge = YamiboWAFChallenge(url: YamiboDomain.baseURL, method: "GET", userAgent: snapshot.session.userAgent,
                clearanceFingerprint: clearance.map { YamiboWAFChallenge.clearanceFingerprint(for: $0.value) },
                clearanceExpiresAt: clearance?.expiresAt)
            _ = try? await recovery.recover(challenge: challenge, context: sessionStore.forumRequestContext(snapshot: snapshot),
                                            lease: .init(duration: .seconds(8)))
        }
    }

    public func attachWebView(to container: UIView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard !isChangingAccount else { return }
        cookieSyncTask?.cancel()
        cookieSyncTask = Task { [weak self] in await self?.synchronizeCookies() }
    }

    private func synchronizeCookies() async {
        let generation = webGeneration
        guard !isChangingAccount, !Task.isCancelled,
              let snapshot = try? await sessionStore.snapshot() else { return }
        let cookies = await cookieStore.allCookies().map { YamiboCookie($0) }
            .filter { YamiboDomain.isYamiboCookieDomain($0.domain) }
        guard generation == webGeneration, !isChangingAccount, !Task.isCancelled else { return }
        try? await sessionStore.updateWebSession(cookies: cookies,
            userAgent: webView.customUserAgent ?? snapshot.session.userAgent, expectedGeneration: snapshot.generation)
    }

    func openLoginPage() async {
        silentFailure = nil
        wafBridge.cancel()
        let generation = webGeneration
        guard !isChangingAccount, let snapshot = try? await sessionStore.snapshot() else { return }
        webView.customUserAgent = snapshot.session.userAgent
        for cookie in snapshot.session.cookies where !cookie.isExpired() {
            if let cookie = cookie.httpCookie() { await cookieStore.setCookieAsync(cookie) }
            guard generation == webGeneration, !isChangingAccount, !Task.isCancelled else { return }
        }
        webView.load(URLRequest(url: YamiboRoute.login.url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func prepareForAccountChange() async {
        isChangingAccount = true
        wafBridge.cancel()
        webGeneration = UUID()
        cookieSyncTask?.cancel()
        preheatTask?.cancel()
        let pending = [cookieSyncTask, preheatTask].compactMap { $0 }
        cookieSyncTask = nil
        preheatTask = nil
        webView.stopLoading()
        navigationLogs.finishAll(error: CancellationError())
        await recovery.invalidate(scopeID: sessionStore.forumScopeID)
        for task in pending { await task.value }
    }

    func finishAccountChange(_ session: SessionState) async {
        for cookie in await cookieStore.allCookies() where YamiboDomain.containsYamiboDomain(cookie.domain) {
            await cookieStore.deleteCookieAsync(cookie)
        }
        webView.customUserAgent = session.userAgent
        for cookie in session.cookies where !cookie.isExpired() {
            if let cookie = cookie.httpCookie() { await cookieStore.setCookieAsync(cookie) }
        }
        lastPreheatAt = nil
        isChangingAccount = false
    }

    func tearDown() async {
        await prepareForAccountChange()
        cookieStore.remove(self)
        webView.navigationDelegate = nil
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationLogs.start(navigation, webView: webView)
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        navigationLogs.redirect(navigation, webView: webView)
        wafBridge.redirected(webView)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        wafBridge.finished(webView)
        navigationLogs.finish(navigation)
        cookiesDidChange(in: cookieStore)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationLogs.finish(navigation, error: error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationLogs.finish(navigation, error: error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationLogs.processTerminated()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        navigationLogs.receive(navigationResponse)
        decisionHandler(navigationResponse.canShowMIMEType && wafBridge.receive(navigationResponse, webView: webView) ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !isChangingAccount, await wafBridge.admit(navigationAction, in: webView) else { return .cancel }
        navigationLogs.allow(navigationAction)
        return .allow
    }
}

public struct ForumWebSessionWebViewHost: UIViewRepresentable {
    public let coordinator: ForumWebSessionCoordinator

    public func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        coordinator.attachWebView(to: view)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        coordinator.attachWebView(to: uiView)
    }
}
#endif

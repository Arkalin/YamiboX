import Observation
import SwiftUI
import WebKit
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
@Observable
public final class ForumWebSessionCoordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKScriptMessageHandler, YamiboWAFChallengeRecovering {
    public enum Presentation: Identifiable, Hashable {
        case verification
        case fallback(URL)

        public var id: String {
            switch self {
            case .verification: "verification"
            case let .fallback(url): "fallback-\(url.absoluteString)"
            }
        }
    }

    private struct Flight {
        var baselineClearance: YamiboCookie?
        var hasDemandWaiter: Bool
        var restoreCookie: YamiboCookie?
        var isObservingClearance = false
    }

    private let sessionStore: SessionStore
    private let cookieStore: WKHTTPCookieStore
    private var flight: Flight?
    private var waiters: [UUID: CheckedContinuation<YamiboRequestCredentials, Error>] = [:]
    private var silentTimeoutTask: Task<Void, Never>?
    private var cookieSyncTask: Task<Void, Never>?
    private var lastPreheatAt: Date?
    private var isAppActive = false
    private weak var hiddenContainer: UIView?
    private weak var visibleContainer: UIView?

    public private(set) var presentation: Presentation?
    public let webView: WKWebView

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: Self.interactionDetectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.cookieStore = configuration.websiteDataStore.httpCookieStore
        super.init()
        webView.navigationDelegate = self
        controller.add(self, name: "yamiboWAFInteraction")
        cookieStore.add(self)
    }

    public func setAppIsActive(_ active: Bool) {
        isAppActive = active
        if active {
            preheatIfNeeded()
        } else if flight?.hasDemandWaiter == false {
            finishFlight(with: CancellationError(), restorePreheatCookie: true)
        }
    }

    public func recover(from challenge: YamiboWAFChallenge) async throws -> YamiboRequestCredentials {
        guard isAppActive else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            waiters[id] = continuation
            if flight != nil {
                flight?.hasDemandWaiter = true
                return
            }
            startFlight(challenge: challenge, hasDemandWaiter: true, restoreCookie: nil)
        }
    }

    public func presentFallback(for challenge: YamiboWAFChallenge) async {
        await prepareWebView(userAgent: challenge.userAgent)
        presentation = .fallback(challenge.url)
        webView.load(URLRequest(url: challenge.url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    public func attachWebView(to container: UIView, placement: ForumWebSessionWebViewPlacement) {
        switch placement {
        case .hidden: hiddenContainer = container
        case .visible: visibleContainer = container
        }
        installWebView(in: container)
    }

    public func detachWebView(from placement: ForumWebSessionWebViewPlacement) {
        if placement == .visible, presentation == nil, let hiddenContainer {
            installWebView(in: hiddenContainer)
        }
    }

    public func dismissPresentation() {
        if flight != nil {
            finishFlight(with: CancellationError(), restorePreheatCookie: false)
        }
        presentation = nil
        if let hiddenContainer { installWebView(in: hiddenContainer) }
    }

    public func reloadVisiblePage() {
        webView.reload()
    }

    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieSyncTask?.cancel()
        if flight != nil {
            // A successful challenge can set and immediately consume the
            // clearance. Do not make demand recovery wait for the normal
            // observer debounce.
            cookieSyncTask = Task { @MainActor [weak self] in
                await self?.synchronizeCookieSnapshot()
            }
            return
        }
        cookieSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            await self?.synchronizeCookieSnapshot()
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Some challenges do not mutate the DOM until after a redirect. Reading
        // the store here complements the direct store observer without using it
        // as the only persistence signal.
        Task { @MainActor [weak self] in
            await self?.synchronizeCookieSnapshot()
        }
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "yamiboWAFInteraction" else { return }
        if flight?.hasDemandWaiter == true {
            presentation = .verification
        } else if flight != nil {
            finishFlight(with: CancellationError(), restorePreheatCookie: true)
        }
    }

    private func preheatIfNeeded() {
        guard isAppActive, flight == nil else { return }
        if let lastPreheatAt, Date.now.timeIntervalSince(lastPreheatAt) < 10 * 60 { return }
        lastPreheatAt = .now

        Task { @MainActor [weak self] in
            guard let self else { return }
            let session = await sessionStore.load()
            guard session.isLoggedIn, session.hasValidAuthenticationCookie else { return }
            let clearance = session.cookies.first { $0.name == "nox_jst_v1" && !$0.isExpired() }
            let shouldPreheat = clearance == nil || (clearance?.expiresAt?.timeIntervalSinceNow ?? .infinity) <= 5 * 60
            guard shouldPreheat, flight == nil else { return }

            if let clearance {
                await delete(clearance)
            }
            startFlight(
                challenge: YamiboWAFChallenge(url: YamiboDomain.baseURL, method: "GET", userAgent: session.userAgent),
                hasDemandWaiter: false,
                restoreCookie: clearance
            )
        }
    }

    private func startFlight(
        challenge: YamiboWAFChallenge,
        hasDemandWaiter: Bool,
        restoreCookie: YamiboCookie?
    ) {
        guard flight == nil else { return }
        flight = Flight(baselineClearance: nil, hasDemandWaiter: hasDemandWaiter, restoreCookie: restoreCookie)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await prepareWebView(userAgent: challenge.userAgent)
            let cookies = await cookieStore.allCookiesAsync()
                .map { YamiboCookie($0) }
                .filter { YamiboDomain.isYamiboCookieDomain($0.domain) }
            let clearance = cookies.first { $0.name == "nox_jst_v1" && !$0.isExpired() }
            flight?.baselineClearance = clearance
            if hasUsableClearance(clearance, replacing: challenge) {
                try? await sessionStore.updateWebSession(
                    cookies: cookies,
                    userAgent: webView.customUserAgent ?? YamiboNetworkConfiguration.defaultMobileUserAgent
                )
                let session = await sessionStore.load()
                finishFlight(with: .success(session.credentials), restorePreheatCookie: false)
                return
            }
            flight?.isObservingClearance = true
            webView.load(URLRequest(url: challenge.url, cachePolicy: .reloadIgnoringLocalCacheData))
            beginSilentTimeout()
        }
    }

    private func beginSilentTimeout() {
        silentTimeoutTask?.cancel()
        silentTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, flight != nil else { return }
            if flight?.hasDemandWaiter == true {
                presentation = .verification
            } else {
                finishFlight(with: CancellationError(), restorePreheatCookie: true)
            }
        }
    }

    private func prepareWebView(userAgent: String) async {
        webView.customUserAgent = userAgent
        let session = await sessionStore.load()
        if session.cookies.isEmpty, !session.isLoggedIn {
            let existing = await cookieStore.allCookiesAsync()
            for cookie in existing where YamiboDomain.containsYamiboDomain(cookie.domain) {
                await delete(cookie)
            }
            return
        }

        let existing = Dictionary(uniqueKeysWithValues: await cookieStore.allCookiesAsync().map { cookie in
            let stored = YamiboCookie(cookie)
            return (stored.identity, stored)
        })
        for cookie in session.cookies where !cookie.isExpired() {
            if let current = existing[cookie.identity], YamiboCookie.isWAFCookie(cookie.name),
               !current.isExpired(),
               (current.expiresAt ?? .distantFuture) >= (cookie.expiresAt ?? .distantPast) {
                continue
            }
            if let httpCookie = cookie.httpCookie() {
                await cookieStore.setCookieAsync(httpCookie)
            }
        }
    }

    private func synchronizeCookieSnapshot() async {
        let cookies = await cookieStore.allCookiesAsync()
            .map { YamiboCookie($0) }
            .filter { YamiboDomain.isYamiboCookieDomain($0.domain) }
        let userAgent = webView.customUserAgent ?? YamiboNetworkConfiguration.defaultMobileUserAgent
        try? await sessionStore.updateWebSession(cookies: cookies, userAgent: userAgent)

        guard let flight, flight.isObservingClearance else { return }
        let clearance = cookies.first { $0.name == "nox_jst_v1" && !$0.isExpired() }
        guard isUpdatedClearance(clearance, since: flight.baselineClearance) else { return }
        let session = await sessionStore.load()
        finishFlight(with: .success(session.credentials), restorePreheatCookie: false)
    }

    private func isUpdatedClearance(_ current: YamiboCookie?, since baseline: YamiboCookie?) -> Bool {
        guard let current, current.expiresAt?.timeIntervalSinceNow ?? 0 > 60 else { return false }
        guard let baseline else { return true }
        return current.value != baseline.value || current.expiresAt != baseline.expiresAt
    }

    private func hasUsableClearance(_ cookie: YamiboCookie?, replacing challenge: YamiboWAFChallenge) -> Bool {
        guard let cookie, cookie.expiresAt?.timeIntervalSinceNow ?? 0 > 60 else { return false }
        guard let expectedFingerprint = challenge.clearanceFingerprint else { return true }
        return YamiboWAFChallenge.clearanceFingerprint(for: cookie.value) != expectedFingerprint
    }

    private func finishFlight(with result: Result<YamiboRequestCredentials, Error>, restorePreheatCookie: Bool) {
        let restoreCookie = restorePreheatCookie ? flight?.restoreCookie : nil
        flight = nil
        silentTimeoutTask?.cancel()
        silentTimeoutTask = nil
        if case .verification = presentation { presentation = nil }
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations { continuation.resume(with: result) }
        if let restoreCookie, !restoreCookie.isExpired(), let httpCookie = restoreCookie.httpCookie() {
            Task { @MainActor [weak self] in
                await self?.cookieStore.setCookieAsync(httpCookie)
                await self?.synchronizeCookieSnapshot()
            }
        }
        if presentation == nil, let hiddenContainer { installWebView(in: hiddenContainer) }
    }

    private func finishFlight(with error: Error, restorePreheatCookie: Bool) {
        finishFlight(with: .failure(error), restorePreheatCookie: restorePreheatCookie)
    }

    private func installWebView(in container: UIView) {
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

    private func delete(_ cookie: YamiboCookie) async {
        let cookies = await cookieStore.allCookiesAsync()
        for candidate in cookies {
            let stored = YamiboCookie(candidate)
            if stored.identity == cookie.identity {
                await delete(candidate)
            }
        }
    }

    private func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            cookieStore.delete(cookie) { continuation.resume() }
        }
    }

    private static let interactionDetectionScript = """
    (() => {
      const text = (document.body?.innerText || '').toLowerCase();
      const selector = '[name*=captcha i], [name*=seccode i], .geetest_holder, iframe[src*=captcha i], iframe[src*=geetest i]';
      if (document.querySelector(selector) || text.includes('验证码') || text.includes('滑块验证')) {
        window.webkit?.messageHandlers?.yamiboWAFInteraction?.postMessage('interaction');
      }
    })();
    """
}

public enum ForumWebSessionWebViewPlacement: Equatable {
    case hidden
    case visible
}

public struct ForumWebSessionWebViewHost: UIViewRepresentable {
    public let coordinator: ForumWebSessionCoordinator
    public let placement: ForumWebSessionWebViewPlacement

    public func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        coordinator.attachWebView(to: view, placement: placement)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        coordinator.attachWebView(to: uiView, placement: placement)
    }

}

public struct ForumWAFVerificationView: View {
    public let coordinator: ForumWebSessionCoordinator

    public var body: some View {
        NavigationStack {
            ForumWebSessionWebViewHost(coordinator: coordinator, placement: .visible)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: coordinator.dismissPresentation) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(L10n.string("common.close"))
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: coordinator.reloadVisiblePage) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(L10n.string("common.retry"))
                    }
                }
        }
    }
}

private extension WKHTTPCookieStore {
    func allCookiesAsync() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }

    func setCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            setCookie(cookie) { continuation.resume() }
        }
    }
}
#endif

import SwiftUI
import WebKit
import YamiboXCore

#if os(iOS)
import UIKit

public struct IOSForumWebView: UIViewRepresentable {
    public let model: ForumBrowserModel
    public let sessionStore: SessionStore
    public let isSelected: Bool

    public init(model: ForumBrowserModel, sessionStore: SessionStore, isSelected: Bool = true) {
        self.model = model
        self.sessionStore = sessionStore
        self.isSelected = isSelected
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: model, sessionStore: sessionStore)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(.yamiboHideChromeScript(for: context.environment.colorScheme))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        context.coordinator.applyAppearance(to: webView, colorScheme: context.environment.colorScheme)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(webView)
        return webView
    }

    public func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.attach(view)
        context.coordinator.applyAppearance(to: view, colorScheme: context.environment.colorScheme)
        if isSelected {
            context.coordinator.synchronizeCurrentSession(reloadIfNeeded: true)
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: ForumBrowserModel
        private let sessionStore: SessionStore
        private weak var webView: WKWebView?
        private var didPrepareInitialLoad = false
        private var appliedColorScheme: ColorScheme?
        private var sessionObservationTask: Task<Void, Never>?
        private var sessionSyncState = ForumWebSessionSyncState()

        init(model: ForumBrowserModel, sessionStore: SessionStore) {
            self.model = model
            self.sessionStore = sessionStore
        }

        deinit {
            sessionObservationTask?.cancel()
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            model.attach(webView: webView)
            startObservingSessionChanges()

            guard !didPrepareInitialLoad else { return }
            didPrepareInitialLoad = true

            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                let sessionState = await sessionStore.load()
                await synchronizeWebViewSession(sessionState, reloadIfNeeded: false)
                if webView.url == nil {
                    model.load(model.currentURL ?? YamiboDomain.baseURL)
                }
            }
        }

        func applyAppearance(to webView: WKWebView, colorScheme: ColorScheme) {
            let isDark = colorScheme == .dark
            let backgroundColor = isDark
                ? YamiboColors.Site.creamBackgroundDarkUIColor
                : YamiboColors.Site.creamBackgroundUIColor
            webView.overrideUserInterfaceStyle = isDark ? .dark : .light
            webView.backgroundColor = backgroundColor
            webView.scrollView.backgroundColor = backgroundColor

            guard appliedColorScheme != colorScheme else { return }
            appliedColorScheme = colorScheme

            let script = WKUserScript.yamiboHideChromeScript(for: colorScheme)
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(script)
            webView.evaluateJavaScript(script.source)
        }

        func synchronizeCurrentSession(reloadIfNeeded: Bool) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sessionState = await sessionStore.load()
                await synchronizeWebViewSession(sessionState, reloadIfNeeded: reloadIfNeeded)
            }
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.sync(with: webView)
        }

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.sync(with: webView)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.sync(with: webView)
            Task {
                do {
                    try await persistCookies(from: webView)
                } catch {
                    YamiboLog.forum.error("Failed to persist web session cookies after navigation finished: \(error)")
                }
            }
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            model.sync(with: webView)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            model.sync(with: webView)
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame == nil, isInternal(url) {
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }

            if !isInternal(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isInternal(url) {
                    webView.load(URLRequest(url: url))
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        private func isInternal(_ url: URL) -> Bool {
            YamiboDomain.isYamiboHost(url)
        }

        private func startObservingSessionChanges() {
            guard sessionObservationTask == nil else { return }

            // `sessionStore` is captured directly (not through `self`) so the
            // stream can be obtained even after the coordinator goes away —
            // mirroring how the old NotificationCenter loop outlived `self`
            // until cancellation.
            sessionObservationTask = Task { @MainActor [weak self, sessionStore] in
                for await changeID in sessionStore.changes() {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    // Per-instance stream: the guard is kept as the explicit
                    // "only this exact store instance" contract.
                    guard changeID == sessionStore.changeID else {
                        continue
                    }

                    let sessionState = await sessionStore.load()
                    await synchronizeWebViewSession(sessionState, reloadIfNeeded: true)
                }
            }
        }

        @MainActor
        private func synchronizeWebViewSession(_ sessionState: SessionState, reloadIfNeeded: Bool) async {
            guard let webView else { return }

            // `nilIfBlank`, not `nilIfEmpty`: this file's deleted private
            // `nilIfEmpty` copy trimmed whitespace, so the trimming variant is
            // the behavior-preserving replacement.
            if let userAgent = sessionState.userAgent.nilIfBlank,
               webView.customUserAgent != userAgent {
                webView.customUserAgent = userAgent
            }

            switch sessionSyncState.action(for: sessionState, reloadIfNeeded: reloadIfNeeded) {
            case .none:
                return
            case let .injectCookies(cookieHeader, reload):
                await injectCookies(cookieHeader, into: webView)
                if reload {
                    reloadOrLoad(webView)
                }
            case let .clearCookies(reload):
                await clearYamiboCookies(in: webView)
                if reload {
                    reloadOrLoad(webView)
                }
            }
        }

        @MainActor
        private func reloadOrLoad(_ webView: WKWebView) {
            if webView.url == nil {
                model.load(model.currentURL ?? YamiboDomain.baseURL)
            } else if let url = webView.url, isInternal(url) {
                webView.reload()
            }
        }

        private func injectCookies(_ cookieHeader: String, into webView: WKWebView) async {
            let cookies = cookieHeader
                .split(separator: ";")
                .compactMap { cookiePart -> HTTPCookie? in
                    let pair = cookiePart.split(separator: "=", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { return nil }
                    return HTTPCookie(properties: [
                        .domain: YamiboDomain.forumHost,
                        .path: "/",
                        .name: pair[0].trimmingCharacters(in: .whitespaces),
                        .value: pair[1].trimmingCharacters(in: .whitespaces),
                        .secure: "TRUE"
                    ])
                }

            await clearConflictingYamiboCookies(for: cookies, in: webView)
            for cookie in cookies {
                await webView.configuration.websiteDataStore.httpCookieStore.setCookieAsync(cookie)
            }
        }

        private func clearConflictingYamiboCookies(for cookies: [HTTPCookie], in webView: WKWebView) async {
            let incomingNames = Set(cookies.map(\.name))
                .union([SessionState.authenticationCookieName])
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let storedCookies = await cookieStore.allCookies()
            for cookie in storedCookies
                where YamiboDomain.containsYamiboDomain(cookie.domain) &&
                incomingNames.contains(cookie.name) {
                await cookieStore.deleteCookieAsync(cookie)
            }
        }

        private func clearYamiboCookies(in webView: WKWebView) async {
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let cookies = await cookieStore.allCookies()
            for cookie in cookies where YamiboDomain.containsYamiboDomain(cookie.domain) {
                await cookieStore.deleteCookieAsync(cookie)
            }
        }

        private func persistCookies(from webView: WKWebView) async throws {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let header = cookies
                .filter { YamiboDomain.containsYamiboDomain($0.domain) }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            let userAgent = webView.customUserAgent ?? YamiboNetworkConfiguration.defaultMobileUserAgent
            sessionSyncState.markPersistedWebSession(cookieHeader: header)
            try await sessionStore.updateWebSession(
                cookie: header,
                userAgent: userAgent,
                isLoggedIn: SessionState.hasAuthenticationCookie(header)
            )
        }
    }
}

private extension WKUserScript {
    static func yamiboHideChromeScript(for colorScheme: ColorScheme) -> WKUserScript {
        WKUserScript(
            source: yamiboHideChromeSource(for: colorScheme),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    /// Rules that recolor the forum page to match the app's cream/brown theme.
    ///
    /// Light mode blankets known structural containers (wrap/bm/tl/threadlist)
    /// because the site's own light skin is visually inconsistent across them.
    /// Dark mode intentionally stays conservative: only `html,body` get a
    /// background + default text color override. The site has no dark theme
    /// of its own, so we can't know which nested elements set their own
    /// explicit background/text colors (forum posts routinely do, e.g.
    /// per-author BBCode colors) — blanket-overriding those in dark mode
    /// risks illegible text (dark text forced onto a dark box, or vice
    /// versa). Leaving them unset lets explicit site/post colors keep
    /// showing through, same as how per-post author colors are left alone
    /// elsewhere in this app.
    static func yamiboHideChromeSource(for colorScheme: ColorScheme) -> String {
        let themeRules: [String]
        switch colorScheme {
        case .dark:
            themeRules = [
                "html,body{background:#17110D !important;color:#F0D8BC !important;}"
            ]
        default:
            themeRules = [
                "html,body{background:#FFF3D6 !important;color:#6E2B19 !important;}",
                "#wrap,.wrap,.wp,.ct2,.mn,.bm,.bm_c,.threadlist,.tl{background:#FFF3D6 !important;color:#6E2B19 !important;}",
                ".bm,.bm_c,.tl th,.tl td{border-color:rgba(109,58,43,0.18) !important;}",
                ".bm_h,.bm_h h2,.bm_h h3{background:#FFF7E0 !important;color:#6E2B19 !important;}",
                "a{color:#6E2B19 !important;}"
            ]
        }

        let chromeRules = [
            ".foot.flex-box:not(.foot_reply){display:none !important;}",
            ".foot_height{display:none !important;}",
            ".my,.mz{visibility:hidden !important;pointer-events:none !important;}"
        ]

        let rulesJSArray = (themeRules + chromeRules)
            .map { "\"\($0)\"" }
            .joined(separator: ",\n                ")

        return """
            (function() {
                var style = document.getElementById('yamibo-hide-style');
                if (!style) {
                    style = document.createElement('style');
                    style.id = 'yamibo-hide-style';
                    (document.head || document.documentElement).appendChild(style);
                }
                style.innerHTML = [
                    \(rulesJSArray)
                ].join(" ");
            })();
            """
    }
}

private extension WKHTTPCookieStore {
    func setCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func deleteCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            delete(cookie) {
                continuation.resume()
            }
        }
    }
}

#endif

import SwiftUI
import WebKit
import YamiboXCore

#if os(iOS)
import UIKit

public struct IOSForumWebView: UIViewRepresentable {
    @Environment(\.forumTheme) private var theme
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
        let appearance = ForumWebAppearance(theme: theme, colorScheme: context.environment.colorScheme)
        configuration.userContentController.addUserScript(.yamiboHideChromeScript(appearance))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        context.coordinator.applyAppearance(to: webView, appearance: appearance)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.attach(webView)
        return webView
    }

    public func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.attach(view)
        context.coordinator.applyAppearance(
            to: view,
            appearance: ForumWebAppearance(theme: theme, colorScheme: context.environment.colorScheme)
        )
        if isSelected {
            context.coordinator.synchronizeCurrentSession(reloadIfNeeded: true)
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: ForumBrowserModel
        private let sessionStore: SessionStore
        private weak var webView: WKWebView?
        private var didPrepareInitialLoad = false
        private var appliedAppearance: ForumWebAppearance?
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

        fileprivate func applyAppearance(to webView: WKWebView, appearance: ForumWebAppearance) {
            webView.overrideUserInterfaceStyle = appearance.isDark ? .dark : .light
            webView.backgroundColor = appearance.pageBackground
            webView.scrollView.backgroundColor = appearance.pageBackground

            guard appliedAppearance != appearance else { return }
            appliedAppearance = appearance

            let script = WKUserScript.yamiboHideChromeScript(appearance)
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
            case let .injectCookies(reload):
                await injectCookies(sessionState.cookies, into: webView)
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

        private func injectCookies(_ cookies: [YamiboCookie], into webView: WKWebView) async {
            let validCookies = cookies.filter { !$0.isExpired() }
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let stored = await cookieStore.allCookies()
            let storedByIdentity = Dictionary(uniqueKeysWithValues: stored.map { cookie in
                let record = YamiboCookie(cookie)
                return (record.identity, record)
            })

            await clearConflictingYamiboCookies(for: validCookies, in: webView)
            for cookie in validCookies {
                if let current = storedByIdentity[cookie.identity],
                   YamiboCookie.isWAFCookie(cookie.name),
                   !current.isExpired(),
                   (current.expiresAt ?? .distantFuture) >= (cookie.expiresAt ?? .distantPast) {
                    continue
                }
                if let httpCookie = cookie.httpCookie() {
                    await cookieStore.setCookieAsync(httpCookie)
                }
            }
        }

        private func clearConflictingYamiboCookies(for cookies: [YamiboCookie], in webView: WKWebView) async {
            let incomingNames = Set(cookies.map(\.name))
                .union([SessionState.authenticationCookieName])
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let storedCookies = await cookieStore.allCookies()
            for cookie in storedCookies
                where YamiboDomain.containsYamiboDomain(cookie.domain) &&
                incomingNames.contains(cookie.name) &&
                !YamiboCookie.isWAFCookie(cookie.name) {
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

    }
}

fileprivate struct ForumWebAppearance: Equatable {
    let isDark: Bool
    let pageBackground: UIColor
    let pageBackgroundCSS: String
    let surfaceCSS: String
    let webTextCSS: String
    let borderCSS: String

    init(theme: ForumTheme, colorScheme: ColorScheme) {
        isDark = colorScheme == .dark
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        pageBackground = UIColor(theme.pageBackground).resolvedColor(with: traits)
        pageBackgroundCSS = Self.cssColor(pageBackground)
        surfaceCSS = Self.cssColor(UIColor(theme.surface).resolvedColor(with: traits))
        webTextCSS = Self.cssColor(UIColor(theme.webText).resolvedColor(with: traits))
        borderCSS = Self.cssColor(UIColor(theme.border).resolvedColor(with: traits))
    }

    static func == (lhs: ForumWebAppearance, rhs: ForumWebAppearance) -> Bool {
        lhs.isDark == rhs.isDark
            && lhs.pageBackgroundCSS == rhs.pageBackgroundCSS
            && lhs.surfaceCSS == rhs.surfaceCSS
            && lhs.webTextCSS == rhs.webTextCSS
            && lhs.borderCSS == rhs.borderCSS
    }

    private static func cssColor(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = Int((red * 255).rounded())
        let greenByte = Int((green * 255).rounded())
        let blueByte = Int((blue * 255).rounded())
        if alpha >= 0.999 {
            return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
        }
        return "rgba(\(redByte),\(greenByte),\(blueByte),\(String(format: "%.3f", alpha)))"
    }
}

private extension WKUserScript {
    static func yamiboHideChromeScript(_ appearance: ForumWebAppearance) -> WKUserScript {
        WKUserScript(
            source: yamiboHideChromeSource(appearance),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    /// Rules that recolor the forum page to match the active forum theme.
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
    static func yamiboHideChromeSource(_ appearance: ForumWebAppearance) -> String {
        let themeRules: [String]
        if appearance.isDark {
            themeRules = [
                "html,body{background:\(appearance.pageBackgroundCSS) !important;color:\(appearance.webTextCSS) !important;}"
            ]
        } else {
            themeRules = [
                "html,body{background:\(appearance.pageBackgroundCSS) !important;color:\(appearance.webTextCSS) !important;}",
                "#wrap,.wrap,.wp,.ct2,.mn,.bm,.bm_c,.threadlist,.tl{background:\(appearance.pageBackgroundCSS) !important;color:\(appearance.webTextCSS) !important;}",
                ".bm,.bm_c,.tl th,.tl td{border-color:\(appearance.borderCSS) !important;}",
                ".bm_h,.bm_h h2,.bm_h h3{background:\(appearance.surfaceCSS) !important;color:\(appearance.webTextCSS) !important;}",
                "a{color:\(appearance.webTextCSS) !important;}"
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

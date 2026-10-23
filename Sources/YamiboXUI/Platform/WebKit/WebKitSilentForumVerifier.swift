import Foundation
import UIKit
import WebKit
import YamiboXCore

/// Platform capability only: no account store and no presentation authority.
@MainActor
public struct WebKitSilentForumVerifier: ForumSilentVerifying {
    public init() {}

    public func verify(_ request: ForumSilentVerificationRequest) async throws -> ForumWAFResult {
        try Task.checkCancellation()
        let isActive = UIApplication.shared.applicationState == .active
        let backgroundTime = UIApplication.shared.backgroundTimeRemaining
        guard ContinuousClock.now < request.deadline,
              isActive || backgroundTime > 1 else {
            throw ForumWAFFailure.runtimeUnavailable
        }
        // UIKit may report an effectively unlimited budget (DBL_MAX). Clamp
        // before constructing Duration, whose integer representation is finite.
        let available = isActive ? 8 : min(8, backgroundTime - 1)
        let bounded = ForumSilentVerificationRequest(flightID: request.flightID, key: request.key,
            challenge: request.challenge, baseline: request.baseline,
            deadline: min(request.deadline.advanced(by: .milliseconds(-50)), ContinuousClock.now.advanced(by: .seconds(available))))
        return try await SilentForumVerification(request: bounded).run()
    }
}

@MainActor
private final class SilentForumVerification: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let request: ForumSilentVerificationRequest
    private var continuation: CheckedContinuation<ForumWAFResult, any Error>?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var webView: WKWebView?
    private var finishedNavigation = false
    private let navigationLogs = WebNavigationLogCapture(source: .webVerification)

    init(request: ForumSilentVerificationRequest) {
        self.request = request
    }

    func run() async throws -> ForumWAFResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task {
                    do { try await ContinuousClock().sleep(until: request.deadline) }
                    catch { return }
                    finish(.failure(finishedNavigation ? ForumWAFFailure.noUpdatedClearance : .silentTimeout))
                }
                work = Task {
                    do { finish(.success(try await execute())) }
                    catch { finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func execute() async throws -> ForumWAFResult {
        try Task.checkCancellation()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.add(self, name: "yamiboWAFInteraction")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.interactionDetectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view
        view.navigationDelegate = self
        view.customUserAgent = request.key.userAgent
        try await ForumWebCookieBoundary.install(on: view)
        let store = configuration.websiteDataStore.httpCookieStore
        for cookie in request.baseline.cookies where cookie.matches(request.challenge.url) {
            if let cookie = cookie.httpCookie() { await store.setCookieAsync(cookie) }
            try Task.checkCancellation()
        }
        // Never navigate to the original request, which might mutate state.
        guard request.key.origin.contains(YamiboRoute.login.url) else { throw ForumWAFFailure.sessionInvalidated }
        view.load(URLRequest(url: YamiboRoute.login.url, cachePolicy: .reloadIgnoringLocalCacheData))
        while true {
            try Task.checkCancellation()
            guard UIApplication.shared.applicationState == .active || UIApplication.shared.backgroundTimeRemaining > 1 else {
                throw ForumWAFFailure.runtimeUnavailable
            }
            guard ContinuousClock.now < request.deadline else { throw ForumWAFFailure.silentTimeout }
            let cookies = await store.allCookies().map { YamiboCookie($0) }
                .filter { $0.matches(request.challenge.url) }
            try Task.checkCancellation()
            let result = ForumWAFResult(cookies: cookies)
            if result.hasUpdatedClearance(for: request.challenge) { return result }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finish(_ result: Result<ForumWAFResult, any Error>) {
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
        YamiboLog.networking.info("Forum flight=\(self.request.flightID, privacy: .public) verifierResources=released")
        continuation.resume(with: result)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "yamiboWAFInteraction" else { return }
        finish(.failure(ForumWAFFailure.interactionRequired))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationLogs.processTerminated()
        finish(.failure(ForumWAFFailure.processTerminated))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationLogs.finish(navigation, error: error)
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
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
        finishedNavigation = true
        navigationLogs.finish(navigation)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationLogs.receive(navigationResponse)
        guard navigationResponse.canShowMIMEType else {
            navigationLogs.cancel(navigationResponse)
            finish(.failure(ForumWAFFailure.runtimeUnavailable))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, request.key.origin.contains(url) else {
            finish(.failure(ForumWAFFailure.runtimeUnavailable))
            return .cancel
        }
        navigationLogs.allow(navigationAction)
        return .allow
    }

    private static let interactionDetectionScript = """
    (() => {
      const inspect = () => {
        const text = (document.body?.innerText || '').toLowerCase();
        const selector = '[name*=captcha i], [name*=seccode i], .geetest_holder, iframe[src*=captcha i], iframe[src*=geetest i]';
        if (document.querySelector(selector) || text.includes('验证码') || text.includes('滑块验证')) {
          window.webkit?.messageHandlers?.yamiboWAFInteraction?.postMessage('interaction');
        }
      };
      inspect();
      new MutationObserver(inspect).observe(document.documentElement, {subtree:true, childList:true});
    })();
    """
}

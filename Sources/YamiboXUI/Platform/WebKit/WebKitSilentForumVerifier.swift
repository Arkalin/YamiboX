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
    private enum NavigationStage: String {
        case preparing, loadRequested, provisional, responseReceived, finished
    }

    private let request: ForumSilentVerificationRequest
    private var continuation: CheckedContinuation<ForumWAFResult, any Error>?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var webView: WKWebView?
    private var finishedNavigation = false
    private var navigationStage: NavigationStage = .preparing
    private var lastMainFrameStatus: Int?
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
        navigationStage = .loadRequested
        if let document = request.challenge.document {
            guard request.challenge.method == "GET", document.url == request.challenge.url,
                  request.key.origin.contains(document.url) else { throw ForumWAFFailure.sessionInvalidated }
            // Execute the response that actually blocked this read, not a new
            // login-page request which may not receive the same challenge.
            // The main request is not sent by loadSimulatedRequest.
            let response = URLResponse(url: document.url, mimeType: document.mimeType,
                                       expectedContentLength: document.body.count, textEncodingName: document.textEncodingName)
            YamiboLog.networking.info("Forum flight=\(self.request.flightID, privacy: .public) verifierInput=receivedChallenge bytes=\(document.body.count, privacy: .public)")
            view.loadSimulatedRequest(URLRequest(url: document.url, cachePolicy: .reloadIgnoringLocalCacheData),
                                      response: response, responseData: document.body)
        } else {
            // Unknown reads and actions must never be navigated or resubmitted.
            guard request.key.origin.contains(YamiboRoute.login.url) else { throw ForumWAFFailure.sessionInvalidated }
            view.load(URLRequest(url: YamiboRoute.login.url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
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
        let status = lastMainFrameStatus.map(String.init) ?? "none"
        YamiboLog.networking.info("Forum flight=\(self.request.flightID, privacy: .public) verifierResources=released navigationStage=\(self.navigationStage.rawValue, privacy: .public) lastMainFrameHTTP=\(status, privacy: .public)")
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
        navigationStage = .provisional
        navigationLogs.start(navigation, webView: webView)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        navigationLogs.redirect(navigation, webView: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedNavigation = true
        navigationStage = .finished
        navigationLogs.finish(navigation)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame {
            navigationStage = .responseReceived
            if let response = navigationResponse.response as? HTTPURLResponse {
                lastMainFrameStatus = response.statusCode
            }
        }
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
        if let document = request.challenge.document,
           navigationAction.request.httpMethod != "GET" || url != document.url {
            // A challenge may reload its audited read after setting clearance,
            // but it cannot gain navigation authority for any other operation.
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

import Foundation
import WebKit
import YamiboXCore

/// Observes only the user's existing browser. It cannot create a browser or
/// present anything. WebKit does not expose every subresource or redirect body.
@MainActor
final class ForumWebWAFBridge {
    private let sessionStore: SessionStore
    private let executor: ForumRequestExecutor
    private let cookieStorageID = UUID()
    private var cookieBoundaryInstalled = false
    private var context: ForumRequestContext?
    private var request: URLRequest?
    private var response: HTTPURLResponse?
    private var operation = ForumRequestOperation()
    private var recovery: Task<Void, Never>?
    private var isReplay = false
    private var replayNavigationPending = false
    private var generation = UUID()
    private var previousURL: URL?
    private var selfRedirects = 0
    private var hops = 0
    var onFailure: ((ForumWAFFailure) -> Void)?

    init(sessionStore: SessionStore, executor: ForumRequestExecutor) {
        self.sessionStore = sessionStore
        self.executor = executor
    }

    func admit(_ action: WKNavigationAction, in webView: WKWebView) async -> Bool {
        let admissionGeneration = generation
        if !cookieBoundaryInstalled {
            do {
                try await ForumWebCookieBoundary.install(on: webView)
                cookieBoundaryInstalled = true
            } catch {
                if !Task.isCancelled { onFailure?(.runtimeUnavailable) }
                return false
            }
        }
        guard generation == admissionGeneration, !Task.isCancelled else { return false }
        if let url = action.request.url, let origin = ForumOrigin(url: YamiboDomain.baseURL),
           url.host?.lowercased() == origin.host, !origin.contains(url) { return false }
        guard action.targetFrame?.isMainFrame != false else { return true }
        if replayNavigationPending {
            replayNavigationPending = false
            return true
        }
        // A user gesture/reload starts a new logical operation. Redirects do not.
        if request == nil || action.navigationType != .other {
            cancel()
            let navigationGeneration = generation
            guard let snapshot = try? await sessionStore.snapshot(),
                  await sessionStore.isCurrentGeneration(snapshot.generation),
                  generation == navigationGeneration, !Task.isCancelled else { return false }
            context = sessionStore.forumRequestContext(snapshot: snapshot, cookieStorageID: cookieStorageID)
            request = action.request
            operation = ForumRequestOperation()
            isReplay = false
            response = nil
            previousURL = action.request.url
            selfRedirects = 0
            hops = 0
        }
        guard let context, let url = action.request.url else { return false }
        // Same-host, different-port redirects must not inherit the browser jar.
        if let original = request?.url, context.key.origin.contains(original), !context.key.origin.contains(url) { return false }
        return true
    }

    func redirected(_ webView: WKWebView) {
        guard let context, let url = webView.url, context.key.origin.contains(url),
              let original = request?.url, context.key.origin.contains(original) else { return }
        hops += 1
        selfRedirects = previousURL == url ? selfRedirects + 1 : 0
        previousURL = url
        if selfRedirects >= 2 { recover(webView) }
        else if hops > 10 { webView.stopLoading(); onFailure?(.replayExhausted) }
    }

    func receive(_ navigationResponse: WKNavigationResponse, webView: WKWebView) -> Bool {
        guard navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse else { return true }
        self.response = response
        if isChallenge(prefix: Data()) { recover(webView); return false }
        return true
    }

    func finished(_ webView: WKWebView) {
        guard response?.statusCode == 405 else {
            request = nil
            return
        }
        let generation = generation
        Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            let prefix = try? await webView.evaluateJavaScript("document.documentElement.outerHTML.slice(0, 131072)") as? String
            guard self.generation == generation, let prefix, self.isChallenge(prefix: Data(prefix.utf8)) else { return }
            self.recover(webView)
        }
    }

    private func isChallenge(prefix: Data) -> Bool {
        guard let context, let response, let url = request?.url else { return false }
        return ForumWAFResponseClassifier.matches(response: response, prefix: prefix,
            origin: context.key.origin, originalURL: url, leftOrigin: false)
    }

    private func recover(_ webView: WKWebView) {
        guard recovery == nil, let context, let request, let url = response?.url ?? webView.url else { return }
        webView.stopLoading()
        guard !isReplay else { onFailure?(.replayExhausted); return }
        isReplay = true
        let generation = generation
        let safe = (request.httpMethod ?? "GET") == "GET" && request.httpBody == nil
            && ForumWebPagePolicy.allowsAutomaticReadReplay(url)
        recovery = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            defer { if self.generation == generation { recovery = nil } }
            do {
                let challenge = ForumWAFResponseClassifier.challenge(url: url, request: request, credentials: context.credentials)
                let credentials = try await executor.recoverNavigation(context: context,
                    policy: .init(replay: safe ? .safeReadOnce : .never, lease: .init(duration: .seconds(8)), operation: operation), challenge: challenge)
                try Task.checkCancellation()
                guard self.generation == generation, await sessionStore.isCurrentGeneration(context.key.generation) else { return }
                for cookie in credentials.cookies where YamiboCookie.isWAFCookie(cookie.name) {
                    if let cookie = cookie.httpCookie() { await webView.configuration.websiteDataStore.httpCookieStore.setCookieAsync(cookie) }
                    try Task.checkCancellation()
                }
                guard self.generation == generation, await sessionStore.isCurrentGeneration(context.key.generation) else { return }
                replayNavigationPending = true
                webView.load(request)
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                onFailure?(LoadDiagnosticError.classificationError(error) as? ForumWAFFailure ?? .runtimeUnavailable)
            }
        }
    }

    func cancel() {
        generation = UUID()
        recovery?.cancel()
        recovery = nil
        request = nil
        response = nil
        replayNavigationPending = false
    }
}

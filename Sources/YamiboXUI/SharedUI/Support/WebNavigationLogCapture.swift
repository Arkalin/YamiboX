import Foundation
import WebKit
import YamiboXCore

/// WebKit exposes main-frame navigation events, not all HTTP traffic or byte counts.
@MainActor
final class WebNavigationLogCapture {
    private enum NavigationID: Hashable {
        case identified(ObjectIdentifier)
        case unidentified
    }

    private struct NavigationRecord {
        let token: NetworkLogToken
        let navigation: WKNavigation?
        var response: URLResponse?
        var finalURL: URL?
    }

    private let source: NetworkLogSource
    private var allowedRequests: [URLRequest] = []
    private var records: [NavigationID: NavigationRecord] = [:]
    private var order: [NavigationID] = []

    init(source: NetworkLogSource) {
        self.source = source
    }

    isolated deinit {
        finishAll(error: CancellationError())
    }

    func allow(_ action: WKNavigationAction) {
        guard action.targetFrame?.isMainFrame == true,
              let url = action.request.url,
              isHTTP(url) else { return }
        // The request body and headers are unnecessary even in this transient state.
        var request = URLRequest(url: url)
        request.httpMethod = action.request.httpMethod
        allowedRequests.append(request)
        if allowedRequests.count > 16 {
            allowedRequests.removeFirst(allowedRequests.count - 16)
        }
    }

    func start(_ navigation: WKNavigation?, webView: WKWebView) {
        let id = identifier(for: navigation)
        guard records[id] == nil else { return }
        // Only start after WebKit confirms a main-frame load; policy decisions
        // alone can be cancelled or handed off without making a request.
        let index = allowedRequests.lastIndex { $0.url == webView.url }
            ?? allowedRequests.indices.last
        guard let index else { return }
        let request = allowedRequests[index]
        allowedRequests.removeFirst(index + 1)
        records[id] = NavigationRecord(
            token: NetworkLogRecorder.shared.begin(request: request, source: source),
            navigation: navigation,
            finalURL: request.url
        )
        order.append(id)
    }

    func redirect(_ navigation: WKNavigation?, webView: WKWebView) {
        let id = identifier(for: navigation)
        guard let url = webView.url, isHTTP(url), var record = records[id] else { return }
        NetworkLogRecorder.shared.addRedirect(to: record.token, url: url)
        record.finalURL = url
        records[id] = record
        // Redirect action policies do not cause a new provisional navigation.
        allowedRequests.removeAll { $0.url == url }
    }

    func receive(_ navigationResponse: WKNavigationResponse) {
        guard navigationResponse.isForMainFrame else { return }
        let response = navigationResponse.response
        // Response policies do not expose WKNavigation. Prefer the observed
        // destination when an older navigation is finishing during replacement.
        let id = order.last { records[$0]?.finalURL == response.url } ?? order.last
        guard let id,
              var record = records[id] else { return }
        record.finalURL = response.url ?? record.finalURL
        if let response = response as? HTTPURLResponse, let url = response.url {
            // Keep the observed status, but never retain Set-Cookie or other headers.
            record.response = HTTPURLResponse(
                url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: nil
            )
        } else if let url = response.url {
            record.response = URLResponse(
                url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil
            )
        }
        records[id] = record
    }

    func cancel(_ navigationResponse: WKNavigationResponse) {
        guard navigationResponse.isForMainFrame,
              let id = order.last(where: { records[$0]?.finalURL == navigationResponse.response.url })
                ?? order.last else { return }
        finish(id, error: CancellationError())
    }

    func finish(_ navigation: WKNavigation?, error: (any Error)? = nil) {
        finish(identifier(for: navigation), error: error)
    }

    private func finish(_ id: NavigationID, error: (any Error)?) {
        guard let record = records.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        NetworkLogRecorder.shared.finish(
            record.token, response: record.response, error: error, finalURL: record.finalURL
        )
    }

    func finishAll(error: any Error) {
        for record in records.values {
            NetworkLogRecorder.shared.finish(
                record.token, response: record.response, error: error, finalURL: record.finalURL
            )
        }
        records.removeAll()
        order.removeAll()
        allowedRequests.removeAll()
    }

    func processTerminated() {
        finishAll(error: NSError(
            domain: WKErrorDomain,
            code: WKError.Code.webContentProcessTerminated.rawValue
        ))
    }

    private func identifier(for navigation: WKNavigation?) -> NavigationID {
        navigation.map { .identified(ObjectIdentifier($0)) } ?? .unidentified
    }

    private func isHTTP(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

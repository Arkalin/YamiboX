import CryptoKit
import Foundation
import WebKit
import YamiboXCore

/// WebKit's Cookie jar is domain-scoped, not origin-scoped. Navigation
/// delegates cannot strip cookies from images, scripts or other subresources.
@MainActor
enum ForumWebCookieBoundary {
    private static var compilations: [ForumOrigin: Task<WKContentRuleList, any Error>] = [:]

    static func install(on webView: WKWebView) async throws {
        guard let origin = ForumOrigin(url: YamiboDomain.baseURL) else {
            throw ForumWAFFailure.runtimeUnavailable
        }
        let compilation: Task<WKContentRuleList, any Error>
        if let current = compilations[origin] {
            compilation = current
        } else {
            compilation = Task {
                let rootDomain = YamiboDomain.rootDomain
                let root = rootDomain.contains(":")
                    ? NSRegularExpression.escapedPattern(for: "[\(rootDomain)]")
                    : "([a-z0-9-]+\\.)*" + NSRegularExpression.escapedPattern(for: rootDomain)
                let hostName = origin.host.contains(":")
                    ? "[\(origin.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]" : origin.host
                let host = NSRegularExpression.escapedPattern(for: hostName)
                let defaultPort = origin.scheme == "https" ? 443 : 80
                let port = origin.port == defaultPort ? "(:\(origin.port))?" : ":\(origin.port)"
                let rules = [
                    ["trigger": ["url-filter": "^[a-z]+://([^/@]+@)?\(root)(:[0-9]+)?/"],
                     "action": ["type": "block-cookies"]],
                    ["trigger": ["url-filter": "^\(origin.scheme)://\(host)\(port)/"],
                     "action": ["type": "ignore-previous-rules"]]
                ]
                let json = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
                let digest = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
                guard let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "yamibox-forum-cookie-boundary-\(digest)",
                    encodedContentRuleList: String(decoding: json, as: UTF8.self)
                ) else { throw ForumWAFFailure.runtimeUnavailable }
                return ruleList
            }
            compilations[origin] = compilation
        }
        let ruleList = try await compilation.value
        try Task.checkCancellation()
        webView.configuration.userContentController.add(ruleList)
    }
}

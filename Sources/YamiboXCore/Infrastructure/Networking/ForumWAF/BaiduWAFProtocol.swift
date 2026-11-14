import Foundation

/// Baidu NOX owns challenge evidence and clearance, not request retry policy.
enum BaiduWAFProtocol {
    private static let clearanceName = "nox_jst_v1"
    private static let markers = ["window.__noxexpire", "nox_jst_v1", "gangplank", "/nox"]

    static func ownsCookie(_ name: String) -> Bool {
        name.lowercased().hasPrefix("nox_")
    }

    static func isChallenge(_ response: HTTPURLResponse, prefix: Data) -> Bool {
        guard response.statusCode == 405 else { return false }
        if response.value(forHTTPHeaderField: "Server")?.localizedCaseInsensitiveContains("baidu_waf") == true
            || response.value(forHTTPHeaderField: "bdwaf-request-id")?.isEmpty == false { return true }
        // The bounded prefix may end mid-scalar. Preserve earlier ASCII evidence.
        let body = String(decoding: prefix.prefix(ForumWAFResponseClassifier.maximumBodyBytes), as: UTF8.self).lowercased()
        return markers.filter { body.contains($0) }.count >= 2
    }

    static func clearance(in cookies: [YamiboCookie], for url: URL, at date: Date) -> YamiboCookie? {
        cookies.first { $0.name == clearanceName && $0.matches(url, at: date) }
    }

    static func hasUpdatedClearance(in cookies: [YamiboCookie], for challenge: YamiboWAFChallenge, at date: Date) -> Bool {
        cookies.contains { cookie in
            cookie.name == clearanceName && cookie.matches(challenge.url, at: date)
                && (cookie.expiresAt?.timeIntervalSince(date) ?? 0) > 60
                && (YamiboWAFChallenge.clearanceFingerprint(for: cookie.value) != challenge.clearanceFingerprint
                    || cookie.expiresAt != challenge.clearanceExpiresAt)
        }
    }
}

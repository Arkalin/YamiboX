import Foundation

public enum ForumWAFResponseClassifier {
    public static let maximumBodyBytes = 128 * 1024
    private static let markers = ["window.__noxexpire", "nox_jst_v1", "gangplank", "/nox"]

    public static func matches(
        response: HTTPURLResponse, prefix: Data, origin: ForumOrigin,
        originalURL: URL, leftOrigin: Bool
    ) -> Bool {
        guard !leftOrigin, origin.contains(originalURL),
              let finalURL = response.url, origin.contains(finalURL), response.statusCode == 405 else { return false }
        if response.value(forHTTPHeaderField: "Server")?.localizedCaseInsensitiveContains("baidu_waf") == true
            || response.value(forHTTPHeaderField: "bdwaf-request-id")?.isEmpty == false { return true }
        let inspected = prefix.prefix(maximumBodyBytes)
        // A bounded prefix can end mid-scalar; keep earlier ASCII evidence
        // instead of rejecting the whole prefix as malformed UTF-8.
        let body = String(decoding: inspected, as: UTF8.self).lowercased()
        return markers.filter { body.contains($0) }.count >= 2
    }

    public static func challenge(url: URL, request: URLRequest, credentials: YamiboRequestCredentials) -> YamiboWAFChallenge {
        let clearance = credentials.cookies.first { $0.name == "nox_jst_v1" && $0.matches(url) }
        return YamiboWAFChallenge(
            url: url, method: request.httpMethod ?? "GET", userAgent: credentials.userAgent,
            clearanceFingerprint: clearance.map { YamiboWAFChallenge.clearanceFingerprint(for: $0.value) },
            clearanceExpiresAt: clearance?.expiresAt
        )
    }
}

/// One instance per attempt. Used for delegate hops and actual metrics alike.
struct ForumRedirectEvidence: Sendable {
    let origin: ForumOrigin
    let originalURL: URL
    private(set) var leftOrigin = false
    private(set) var consecutiveSelfRedirects = 0
    private(set) var count = 0
    private(set) var challengeURL: URL?

    mutating func observe(from: URL, to: URL) {
        count += 1
        if !origin.contains(from) || !origin.contains(to) { leftOrigin = true }
        if !leftOrigin, origin.contains(originalURL), from == to {
            consecutiveSelfRedirects += 1
            if consecutiveSelfRedirects >= 2 { challengeURL = from }
        } else {
            consecutiveSelfRedirects = 0
        }
    }
}

import Foundation

public enum ForumWAFResponseClassifier {
    public static let maximumBodyBytes = 128 * 1024

    public static func mayContainChallenge(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 405 || AliyunWAFProtocol.mayContainChallenge(response)
    }

    public static func matches(
        response: HTTPURLResponse, prefix: Data, origin: ForumOrigin,
        originalURL: URL, leftOrigin: Bool
    ) -> Bool {
        provider(response: response, prefix: prefix, origin: origin, originalURL: originalURL, leftOrigin: leftOrigin) != nil
    }

    private static func provider(response: HTTPURLResponse, prefix: Data, origin: ForumOrigin,
                                 originalURL: URL, leftOrigin: Bool) -> ForumWAFProvider? {
        guard !leftOrigin, origin.contains(originalURL),
              let finalURL = response.url, origin.contains(finalURL) else { return nil }
        if BaiduWAFProtocol.isChallenge(response, prefix: prefix) { return .baidu }
        if AliyunWAFProtocol.isChallenge(response, prefix: prefix) { return .aliyun }
        return nil
    }

    public static func challenge(response: HTTPURLResponse, prefix: Data, origin: ForumOrigin,
                                 request: URLRequest, credentials: YamiboRequestCredentials, leftOrigin: Bool,
                                 document: ForumWAFChallengeDocument? = nil) -> YamiboWAFChallenge? {
        guard let originalURL = request.url, let url = response.url,
              let provider = provider(response: response, prefix: prefix, origin: origin,
                                      originalURL: originalURL, leftOrigin: leftOrigin) else { return nil }
        return challenge(url: url, request: request, credentials: credentials, document: document, provider: provider)
    }

    public static func challenge(url: URL, request: URLRequest, credentials: YamiboRequestCredentials,
                                 document: ForumWAFChallengeDocument? = nil,
                                 provider: ForumWAFProvider = .baidu) -> YamiboWAFChallenge {
        let clearance = ForumWAFResult(cookies: credentials.cookies).clearance(for: url, provider: provider)
        return YamiboWAFChallenge(
            url: url, method: request.httpMethod ?? "GET", userAgent: credentials.userAgent,
            clearanceFingerprint: clearance.map { YamiboWAFChallenge.clearanceFingerprint(for: $0.value) },
            clearanceExpiresAt: clearance?.expiresAt, document: document, provider: provider
        )
    }
}

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

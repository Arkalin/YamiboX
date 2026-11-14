import CryptoKit
import Foundation

public struct YamiboWAFChallenge: Hashable, Sendable {
    public let url: URL
    public let method: String
    public let userAgent: String
    public let provider: ForumWAFProvider
    public let document: ForumWAFChallengeDocument?
    /// A one-way comparison value. It lets the WebKit owner decide whether it
    /// already has a newer clearance without passing a cookie value across the
    /// Core/UI boundary.
    public let clearanceFingerprint: String?
    public let clearanceExpiresAt: Date?

    public init(
        url: URL,
        method: String,
        userAgent: String,
        clearanceFingerprint: String? = nil,
        clearanceExpiresAt: Date? = nil,
        document: ForumWAFChallengeDocument? = nil,
        provider: ForumWAFProvider = .baidu
    ) {
        self.url = url
        self.method = method
        self.userAgent = userAgent
        self.document = document
        self.provider = provider
        self.clearanceFingerprint = clearanceFingerprint
        self.clearanceExpiresAt = clearanceExpiresAt
    }

    /// Recovery tickets retain evidence, not executable response bodies.
    func withoutDocument() -> Self {
        Self(url: url, method: method, userAgent: userAgent, clearanceFingerprint: clearanceFingerprint,
             clearanceExpiresAt: clearanceExpiresAt, provider: provider)
    }

    public static func clearanceFingerprint(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

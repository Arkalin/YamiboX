import CryptoKit
import Foundation

public struct YamiboWAFChallenge: Hashable, Sendable {
    public let url: URL
    public let method: String
    public let userAgent: String
    public let provider: ForumWAFProvider
    public let document: ForumWAFChallengeDocument?
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

    func withoutDocument() -> Self {
        Self(url: url, method: method, userAgent: userAgent, clearanceFingerprint: clearanceFingerprint,
             clearanceExpiresAt: clearanceExpiresAt, provider: provider)
    }

    public static func clearanceFingerprint(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

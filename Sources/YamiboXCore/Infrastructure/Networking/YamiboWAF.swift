import CryptoKit
import Foundation

public struct YamiboWAFChallenge: Hashable, Sendable {
    public let url: URL
    public let method: String
    public let userAgent: String
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
        clearanceExpiresAt: Date? = nil
    ) {
        self.url = url
        self.method = method
        self.userAgent = userAgent
        self.clearanceFingerprint = clearanceFingerprint
        self.clearanceExpiresAt = clearanceExpiresAt
    }

    public static func clearanceFingerprint(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

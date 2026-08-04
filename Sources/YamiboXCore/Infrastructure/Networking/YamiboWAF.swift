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

/// UI code owns WebKit and conforms to this protocol; the Core networking
/// layer only knows that a verified set of credentials can be requested.
public protocol YamiboWAFChallengeRecovering: Sendable {
    func recover(from challenge: YamiboWAFChallenge) async throws -> YamiboRequestCredentials
    func presentFallback(for challenge: YamiboWAFChallenge) async
}

enum YamiboWAFResponseDetector {
    private static let markers = [
        "window.__noxexpire",
        "nox_jst_v1",
        "gangplank",
        "/nox"
    ]

    static func matches(data: Data, response: HTTPURLResponse, requestURL: URL) -> Bool {
        guard response.statusCode == 405, YamiboDomain.isYamiboHost(requestURL) else { return false }
        let headers = normalizedHeaders(response)
        if headers["server"]?.localizedCaseInsensitiveContains("baidu_waf") == true {
            return true
        }
        if headers["bdwaf-request-id"]?.isEmpty == false {
            return true
        }

        let inspectedData = data.prefix(128 * 1024)
        let body = String(data: inspectedData, encoding: .utf8)?.lowercased()
            ?? String(data: inspectedData, encoding: .unicode)?.lowercased()
            ?? ""
        return markers.reduce(into: 0) { count, marker in
            if body.contains(marker) { count += 1 }
        } >= 2
    }

    private static func normalizedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        Dictionary(uniqueKeysWithValues: response.allHeaderFields.map { key, value in
            (String(describing: key).lowercased(), String(describing: value))
        })
    }
}

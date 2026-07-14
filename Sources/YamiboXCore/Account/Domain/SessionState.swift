import Foundation

public struct SessionState: Codable, Hashable, Sendable {
    public static let authenticationCookieName = "EeqY_2132_auth"

    public var cookie: String
    public var userAgent: String
    public var isLoggedIn: Bool
    public var lastUpdatedAt: Date?
    public var accountUID: String?

    public init(
        cookie: String = "",
        userAgent: String = YamiboNetworkConfiguration.defaultMobileUserAgent,
        isLoggedIn: Bool = false,
        lastUpdatedAt: Date? = nil,
        accountUID: String? = nil
    ) {
        self.cookie = cookie
        self.userAgent = userAgent
        self.isLoggedIn = isLoggedIn
        self.lastUpdatedAt = lastUpdatedAt
        self.accountUID = accountUID
    }

    public static func hasAuthenticationCookie(_ cookieHeader: String) -> Bool {
        authenticationCookieValue(in: cookieHeader) != nil
    }

    public static func authenticationCookieValue(in cookieHeader: String) -> String? {
        cookieHeader
            .split(separator: ";")
            .compactMap { part -> String? in
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { return nil }
                let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard name == authenticationCookieName else { return nil }
                return normalizedAuthenticationCookieValue(pair[1])
            }
            .first
    }

    private static func normalizedAuthenticationCookieValue(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           value.first == "\"",
           value.last == "\"" {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !value.isEmpty else { return nil }

        let deletedValues: Set<String> = [
            "delete",
            "deleted",
            "expired",
            "nil",
            "none",
            "null"
        ]
        guard !deletedValues.contains(value.lowercased()) else { return nil }

        return value
    }
}

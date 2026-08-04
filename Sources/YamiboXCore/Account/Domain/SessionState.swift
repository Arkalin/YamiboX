import Foundation

public struct SessionState: Codable, Hashable, Sendable {
    public static let authenticationCookieName = "EeqY_2132_auth"

    public var cookies: [YamiboCookie]
    /// Compatibility projection for callers that still need a Cookie header.
    /// New code must retain cookie metadata through `cookies` instead.
    public var cookie: String {
        get { YamiboRequestCredentials(cookies: cookies, userAgent: userAgent).cookieHeader(for: YamiboDomain.baseURL) }
        set { cookies = YamiboCookie.legacyCookies(from: newValue, capturedAt: lastUpdatedAt ?? .now) }
    }
    public var userAgent: String
    public var isLoggedIn: Bool
    public var lastUpdatedAt: Date?
    public var accountUID: String?

    public init(
        cookie: String = "",
        cookies: [YamiboCookie]? = nil,
        userAgent: String = YamiboNetworkConfiguration.defaultMobileUserAgent,
        isLoggedIn: Bool = false,
        lastUpdatedAt: Date? = nil,
        accountUID: String? = nil
    ) {
        self.cookies = cookies ?? YamiboCookie.legacyCookies(from: cookie, capturedAt: lastUpdatedAt ?? .now)
        self.userAgent = userAgent
        self.isLoggedIn = isLoggedIn
        self.lastUpdatedAt = lastUpdatedAt
        self.accountUID = accountUID
    }

    public var credentials: YamiboRequestCredentials {
        YamiboRequestCredentials(cookies: cookies, userAgent: userAgent)
    }

    public var authenticationCookie: YamiboCookie? {
        cookies.first {
            $0.name == Self.authenticationCookieName && !$0.isExpired()
        }
    }

    public var hasValidAuthenticationCookie: Bool {
        authenticationCookie != nil
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

    private enum CodingKeys: String, CodingKey {
        case cookies
        case cookie
        case userAgent
        case isLoggedIn
        case lastUpdatedAt
        case accountUID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent) ?? YamiboNetworkConfiguration.defaultMobileUserAgent
        isLoggedIn = try container.decodeIfPresent(Bool.self, forKey: .isLoggedIn) ?? false
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        accountUID = try container.decodeIfPresent(String.self, forKey: .accountUID)
        if let storedCookies = try container.decodeIfPresent([YamiboCookie].self, forKey: .cookies) {
            cookies = storedCookies
        } else {
            let legacyHeader = try container.decodeIfPresent(String.self, forKey: .cookie) ?? ""
            cookies = YamiboCookie.legacyCookies(from: legacyHeader, capturedAt: lastUpdatedAt ?? .now)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cookies, forKey: .cookies)
        try container.encode(userAgent, forKey: .userAgent)
        try container.encode(isLoggedIn, forKey: .isLoggedIn)
        try container.encodeIfPresent(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encodeIfPresent(accountUID, forKey: .accountUID)
    }
}

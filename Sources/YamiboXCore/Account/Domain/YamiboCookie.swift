import Foundation

/// A persistable representation of a forum cookie. Keeping the cookie shape
/// intact prevents short-lived WAF credentials from being revived as session
/// cookies after their original expiry has passed.
public struct YamiboCookie: Codable, Hashable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let capturedAt: Date
    public let isSecure: Bool
    public let isHTTPOnly: Bool
    public let sameSitePolicy: String?

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expiresAt: Date? = nil,
        capturedAt: Date = .now,
        isSecure: Bool = true,
        isHTTPOnly: Bool = false,
        sameSitePolicy: String? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path.isEmpty ? "/" : path
        self.expiresAt = expiresAt
        self.capturedAt = capturedAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSitePolicy = sameSitePolicy
    }

    public var identity: String {
        "\(domain.lowercased())|\(path)|\(name)"
    }

    public func isExpired(at date: Date = .now) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }

    public func matches(_ url: URL, at date: Date = .now) -> Bool {
        guard !isExpired(at: date), let host = url.host?.lowercased() else { return false }
        if isSecure, url.scheme?.lowercased() != "https" { return false }

        let normalizedDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)") else { return false }

        let requestPath = url.path.isEmpty ? "/" : url.path
        guard requestPath.hasPrefix(path) else { return false }
        if path.hasSuffix("/") || requestPath == path { return true }
        return requestPath.dropFirst(path.count).first == "/"
    }

    public static func legacyCookies(from cookieHeader: String, capturedAt: Date = .now) -> [YamiboCookie] {
        cookieHeader
            .split(separator: ";")
            .compactMap { part -> YamiboCookie? in
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { return nil }
                let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty, !isLegacyWAFCookie(name) else { return nil }
                return YamiboCookie(name: name, value: value, domain: YamiboDomain.forumHost, capturedAt: capturedAt)
            }
    }

    public static func isWAFCookie(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized == "nox_jst_v1" || normalized.hasPrefix("nox_")
    }

    private static func isLegacyWAFCookie(_ name: String) -> Bool {
        isWAFCookie(name)
    }
}

public extension YamiboCookie {
    init(_ cookie: HTTPCookie, capturedAt: Date = .now) {
        self.init(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expiresAt: cookie.expiresDate,
            capturedAt: capturedAt,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly,
            sameSitePolicy: cookie.properties?[.sameSitePolicy] as? String
        )
    }

    func httpCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
            .secure: isSecure ? "TRUE" : "FALSE"
        ]
        if let expiresAt { properties[.expires] = expiresAt }
        if let sameSitePolicy { properties[.sameSitePolicy] = sameSitePolicy }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

public struct YamiboRequestCredentials: Hashable, Sendable {
    public let cookies: [YamiboCookie]
    public let userAgent: String

    public init(cookies: [YamiboCookie], userAgent: String) {
        self.cookies = Self.canonicalCookies(cookies)
        self.userAgent = userAgent
    }

    public func cookieHeader(for url: URL, at date: Date = .now) -> String {
        cookies
            .filter { $0.matches(url, at: date) }
            .sorted {
                if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.domain < $1.domain
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func canonicalCookies(_ cookies: [YamiboCookie]) -> [YamiboCookie] {
        var byIdentity: [String: YamiboCookie] = [:]
        for cookie in cookies {
            if let current = byIdentity[cookie.identity], current.capturedAt > cookie.capturedAt { continue }
            byIdentity[cookie.identity] = cookie
        }
        return byIdentity.values.sorted { $0.identity < $1.identity }
    }
}

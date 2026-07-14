import Foundation

/// Central definition of the yamibo.com domain: canonical hosts, base URL
/// construction, and the host / cookie-domain matching rules used across the app.
public enum YamiboDomain: Sendable {
    /// Registrable root domain of the site.
    public static let rootDomain = "yamibo.com"

    /// Host of the main forum site.
    public static let forumHost = "bbs.yamibo.com"

    /// Canonical base URL of the forum ("https://bbs.yamibo.com").
    public static let baseURL = URL(string: "https://\(forumHost)")!

    private static let subdomainSuffix = ".\(rootDomain)"

    // MARK: - URL host matching

    /// Whether the URL points exactly at the main forum host (case-insensitive).
    public static func isForumHost(_ url: URL) -> Bool {
        url.host?.lowercased() == forumHost
    }

    /// Whether the URL points at the forum host or any `*.yamibo.com` subdomain.
    /// The bare root domain ("yamibo.com") intentionally does not match; this is
    /// the allowlist semantic used for in-app web navigation.
    public static func isYamiboHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == forumHost || host.hasSuffix(subdomainSuffix)
    }

    // MARK: - Cookie domain matching

    /// Strict cookie-domain check used when assembling outgoing cookie headers:
    /// matches the bare root domain, the forum host, and any `*.yamibo.com`
    /// domain (including leading-dot cookie domains such as ".yamibo.com").
    public static func isYamiboCookieDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased()
        return normalized == rootDomain
            || normalized == forumHost
            || normalized.hasSuffix(subdomainSuffix)
    }

    /// Broad substring check: whether the value mentions "yamibo.com" anywhere
    /// (case-insensitive). Used for permissive matching such as cookie cleanup
    /// and thread-URL routing, where over-matching is preferable to missing a
    /// yamibo-affiliated host.
    public static func containsYamiboDomain(_ value: String) -> Bool {
        value.lowercased().contains(rootDomain)
    }

    // MARK: - URL construction

    /// Builds an absolute forum URL from a site-relative path, with or without a
    /// leading slash. The path may carry a query string
    /// (e.g. "plugin.php?id=zqlj_sign").
    public static func url(forSitePath path: String) -> URL? {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "https://\(forumHost)\(normalized)")
    }
}

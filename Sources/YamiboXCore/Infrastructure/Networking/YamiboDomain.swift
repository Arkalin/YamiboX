import Foundation

/// Central definition of the selected forum: canonical host, base URL,
/// and the host / cookie-domain matching rules used across the app.
public enum YamiboDomain: Sendable {
    /// Registrable root domain of the production site, or the local host.
    public static var rootDomain: String {
        YamiboForumEnvironment.current.rootDomain
    }

    /// Host of the selected forum site.
    public static var forumHost: String { YamiboForumEnvironment.current.forumHost }

    /// Canonical base URL of the selected forum, including its scheme and port.
    public static var baseURL: URL { YamiboForumEnvironment.current.baseURL }

    // MARK: - URL host matching

    /// Whether the URL points exactly at the main forum host (case-insensitive).
    public static func isForumHost(_ url: URL) -> Bool {
        url.host?.lowercased() == forumHost
    }

    /// Test mode trusts only the configured origin, including its effective port.
    public static func isForumURL(_ url: URL) -> Bool {
        YamiboForumEnvironment.current.isForumURL(url)
    }

    /// Whether the URL points at the forum host or any `*.yamibo.com` subdomain.
    /// The bare root domain ("yamibo.com") intentionally does not match; this is
    /// the allowlist semantic used for in-app web navigation.
    public static func isYamiboHost(_ url: URL) -> Bool {
        YamiboForumEnvironment.current.isSiteURL(url)
    }

    // MARK: - Cookie domain matching

    /// Strict cookie-domain check used when assembling outgoing cookie headers:
    /// matches the bare root domain, the forum host, and any `*.yamibo.com`
    /// domain (including leading-dot cookie domains such as ".yamibo.com").
    public static func isYamiboCookieDomain(_ domain: String) -> Bool {
        YamiboForumEnvironment.current.isCookieDomain(domain)
    }

    /// Production uses the existing broad substring check; test mode uses the
    /// configured site's cookie-domain rules during cookie cleanup.
    public static func containsYamiboDomain(_ value: String) -> Bool {
        YamiboForumEnvironment.current.matchesCookieCleanupDomain(value)
    }

    // MARK: - URL construction

    /// Builds an absolute forum URL from a site-relative path, with or without a
    /// leading slash. The path may carry a query string
    /// (e.g. "plugin.php?id=zqlj_sign").
    public static func url(forSitePath path: String) -> URL? {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: normalized, relativeTo: baseURL)?.absoluteURL
    }
}

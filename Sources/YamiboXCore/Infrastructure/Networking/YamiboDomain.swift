import Foundation

public enum YamiboDomain: Sendable {
    public static var rootDomain: String {
        YamiboForumEnvironment.current.rootDomain
    }

    public static var forumHost: String { YamiboForumEnvironment.current.forumHost }

    public static var baseURL: URL { YamiboForumEnvironment.current.baseURL }


    public static func isForumHost(_ url: URL) -> Bool {
        url.host?.lowercased() == forumHost
    }

    public static func isForumURL(_ url: URL) -> Bool {
        YamiboForumEnvironment.current.isForumURL(url)
    }

    public static func isYamiboHost(_ url: URL) -> Bool {
        YamiboForumEnvironment.current.isSiteURL(url)
    }


    public static func isYamiboCookieDomain(_ domain: String) -> Bool {
        YamiboForumEnvironment.current.isCookieDomain(domain)
    }

    public static func containsYamiboDomain(_ value: String) -> Bool {
        YamiboForumEnvironment.current.matchesCookieCleanupDomain(value)
    }


    public static func url(forSitePath path: String) -> URL? {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: normalized, relativeTo: baseURL)?.absoluteURL
    }
}

import Foundation

public enum ForumWebPagePolicy {
    public static func allowsAutomaticReadReplay(_ url: URL) -> Bool {
        ForumRequestDefinition.navigation(URLRequest(url: url)).allowsAutomaticRetry
    }

    public static func isForumPage(_ url: URL) -> Bool {
        YamiboForumEnvironment.current.isForumPageURL(url)
    }

    public static func isLoginPage(_ url: URL) -> Bool {
        guard isForumPage(url), url.path == "/member.php" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        guard items.filter({ $0.name == "action" }).count <= 1, items.filter({ $0.name == "mod" }).count == 1 else { return false }
        let action = items.first { $0.name == "action" }?.value ?? ""
        return items.first { $0.name == "mod" }?.value == "logging" && ["", "login"].contains(action)
    }

    public static func requiresForumHandling(_ url: URL) -> Bool {
        isForumPage(url) && !isLoginPage(url)
    }

    public static func secureURL(_ url: URL) -> URL {
        YamiboForumEnvironment.current.normalizedForumPageURL(url)
    }

    public static func desktopURL(_ url: URL) -> URL {
        guard requiresForumHandling(url),
              var components = URLComponents(url: secureURL(url), resolvingAgainstBaseURL: true) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "mobile" || $0.name == "forcemobile" }
        items.append(.init(name: "mobile", value: "no"))
        components.queryItems = items
        return components.url ?? url
    }

    public static func requiresConfirmationToLoad(_ url: URL) -> Bool {
        ForumRequestDefinition.requiresConfirmationToLoad(url)
    }
}

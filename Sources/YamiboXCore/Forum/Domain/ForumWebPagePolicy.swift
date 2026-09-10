import Foundation

/// Only authentication and off-site content belong in a browser. Keep this
/// decision shared by URL routing and the WebKit navigation delegate.
public enum ForumWebPagePolicy {
    public static func isForumPage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil else { return false }
        return YamiboDomain.isForumHost(url) && (url.port == nil || url.port == 80 || url.port == 443)
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
        guard isForumPage(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url ?? url
    }

    /// Discuz has state-changing GET links. Never fetch a token-bearing action
    /// simply because a view appeared, a link was previewed, or Retry was tapped.
    public static func requiresConfirmationToLoad(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        if ["action", "op", "mod", "operation"].contains(where: { key in items.filter { $0.name.lowercased() == key }.count > 1 }) { return true }
        let value: (String) -> String = { name in items.first { $0.name.lowercased() == name }?.value?.lowercased() ?? "" }
        if items.contains(where: { $0.name.lowercased().hasSuffix("submit") || $0.name.lowercased() == "formhash" }) {
            return true
        }
        let readActions: Set<String> = ["", "newthread", "reply", "edit", "view", "list", "search", "login", "index", "report", "rate"]
        let readOperations: Set<String> = ["", "view", "show", "showmsg", "edit", "list", "search", "add", "new", "index", "find", "get"]
        if !readActions.contains(value("action")) || !readOperations.contains(value("op")) {
            return true
        }
        return url.path == "/plugin.php" && !value("operation").isEmpty
    }
}

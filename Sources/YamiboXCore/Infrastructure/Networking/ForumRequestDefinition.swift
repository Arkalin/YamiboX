import Foundation

public struct ForumRequestDefinition: Sendable {
    public enum Effect: Sendable { case read, write, unknown }
    enum Credentials: Sendable { case account, protectionOnly }

    public let effect: Effect
    private let permitsRetry: Bool
    let credentials: Credentials

    private init(effect: Effect, permitsRetry: Bool, credentials: Credentials = .account) {
        self.effect = effect
        self.permitsRetry = permitsRetry
        self.credentials = credentials
    }

    static let read = Self(effect: .read, permitsRetry: true)
    static let nonRetryingRead = Self(effect: .read, permitsRetry: false)
    static let write = Self(effect: .write, permitsRetry: false)
    static let unknown = Self(effect: .unknown, permitsRetry: false)
    static let promotion = Self(effect: .write, permitsRetry: false, credentials: .protectionOnly)

    static let resource = read

    public static func navigation(_ request: URLRequest) -> Self {
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil else { return .write }
        guard let url = request.url else { return .unknown }
        if requiresConfirmationToLoad(url) { return .write }
        return isAuditedNavigationRead(url) ? .read : .unknown
    }

    public var allowsAutomaticRetry: Bool { effect == .read && permitsRetry }

    private static func isAuditedNavigationRead(_ url: URL) -> Bool {
        guard ForumWebPagePolicy.isForumPage(url) else { return false }
        if ForumWebPagePolicy.isLoginPage(url) { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String = { name in items.first { $0.name == name }?.value ?? "" }
        if YamiboForumURLIdentity.threadID(from: url.absoluteString) != nil,
           url.path.hasPrefix("/thread-") { return true }
        switch url.path {
        case "/", "/index.php": return items.allSatisfy { ["mobile", "forcemobile"].contains($0.name) }
        case "/forum.php":
            return ["", "forumdisplay", "viewthread", "guide", "attachment", "announcement", "tag"].contains(value("mod"))
                || value("mod") == "post" && ["newthread", "reply", "edit"].contains(value("action"))
                || value("mod") == "misc" && ["rate", "report"].contains(value("action"))
        case "/home.php":
            return value("mod") == "space" && ["", "profile", "thread", "blog", "friend", "favorite"].contains(value("do"))
                || value("mod") == "spacecp" && ["blog", "friend"].contains(value("ac")) && ["", "add", "edit"].contains(value("op"))
        case "/search.php": return !items.contains { ["srchtxt", "searchid"].contains($0.name) }
        default: return false
        }
    }

    public static func requiresConfirmationToLoad(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        if ["action", "op", "mod", "operation"].contains(where: { key in items.filter { $0.name.lowercased() == key }.count > 1 }) { return true }
        let value: (String) -> String = { name in items.first { $0.name.lowercased() == name }?.value?.lowercased() ?? "" }
        if items.contains(where: { $0.name.lowercased().hasSuffix("submit") || $0.name.lowercased() == "formhash" }) {
            return true
        }
        let readActions: Set<String> = ["", "newthread", "reply", "edit", "view", "list", "search", "login", "index", "report", "rate"]
        let readOperations: Set<String> = ["", "view", "show", "showmsg", "edit", "list", "search", "add", "new", "index", "find", "get"]
        if !readActions.contains(value("action")) || !readOperations.contains(value("op")) { return true }
        return url.path == "/plugin.php" && !value("operation").isEmpty
    }

    public func policy(for request: URLRequest, lease: ForumRuntimeLease,
                       operation: ForumRequestOperation = .init(), deliversCompletedInitialResponse: Bool = false) -> ForumRequestPolicy {
        let safe = allowsAutomaticRetry && request.httpMethod == "GET"
            && request.httpBody == nil && request.httpBodyStream == nil
        return ForumRequestPolicy(replay: safe ? .safeReadOnce : .never, lease: lease, operation: operation,
                                  deliversCompletedInitialResponse: deliversCompletedInitialResponse)
    }
}

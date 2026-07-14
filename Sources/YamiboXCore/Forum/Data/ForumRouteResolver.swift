import Foundation

public enum ForumNavigationSource: String, Codable, Hashable, Sendable {
    case external
    case readerOrigin
    /// A novel/manga reader's "查看原帖"-style jump into its own thread.
    /// Same native-thread-reader routing as `.readerOrigin`, but the opened
    /// reader is a discussion companion view for the work's tid, so it must
    /// not produce its own browsing-history row (browsing-history decision
    /// #14) — unlike `.readerOrigin` opens from favorites/history, which are
    /// real visits and do record.
    case readerDiscussion
}

public enum ForumResolvedRoute: Equatable, Hashable, Sendable {
    case home
    case board(fid: String, title: String?, page: Int?)
    case thread(URL)
    case userSpace(uid: String, name: String?)
    case messageCenter(tab: MessageCenterTab)
    case privateMessage(uid: String, name: String?)
    case blog(blogID: String, uid: String?, title: String?)
    case web(URL)
}

public enum ForumRouteResolver {
    public static func resolve(url: URL, source: ForumNavigationSource = .external) -> ForumResolvedRoute {
        let resolvedURL = URL(string: url.absoluteString, relativeTo: YamiboDomain.baseURL)?.absoluteURL ?? url.absoluteURL

        if let board = boardRoute(from: resolvedURL) {
            return .board(fid: board.fid, title: nil, page: board.page)
        }

        if isThreadURL(resolvedURL) {
            return .thread(resolvedURL)
        }

        if let blog = blogRoute(from: resolvedURL) {
            return .blog(blogID: blog.blogID, uid: blog.uid, title: nil)
        }

        if let uid = privateMessageID(from: resolvedURL) {
            return .privateMessage(uid: uid, name: nil)
        }

        if let tab = messageCenterTab(from: resolvedURL) {
            return .messageCenter(tab: tab)
        }

        if let uid = userSpaceID(from: resolvedURL) {
            return .userSpace(uid: uid, name: nil)
        }

        if isForumHomeURL(resolvedURL) {
            return .home
        }

        return .web(resolvedURL)
    }

    public static func boardURL(fid: String, page: Int? = nil) -> URL {
        var components = URLComponents(url: YamiboDomain.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/forum.php"
        components.queryItems = [
            .init(name: "mod", value: "forumdisplay"),
            .init(name: "fid", value: fid),
            .init(name: "mobile", value: "2")
        ]
        if let page, page > 1 {
            components.queryItems?.append(.init(name: "page", value: String(page)))
        }
        return components.url!
    }

    public static func userSpaceURL(uid: String) -> URL {
        YamiboRoute.userSpaceProfile(uid: uid).url
    }

    public static func blogURL(blogID: String, uid: String?) -> URL {
        YamiboRoute.blog(blogID: blogID, uid: uid, page: 1).url
    }

    private static func boardRoute(from url: URL) -> (fid: String, page: Int?)? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = components.queryItems ?? []
            let mod = items.value(named: "mod")
            if mod == "forumdisplay", let fid = items.value(named: "fid")?.nilIfBlank {
                return (fid, items.value(named: "page").flatMap(Int.init))
            }
        }

        if let match = HTMLTextExtractor.firstMatch(pattern: #"forum-(\d+)-(\d+)\.html"#, in: url.absoluteString),
           match.count >= 3 {
            return (match[1], Int(match[2]))
        }

        return nil
    }

    private static func isThreadURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return HTMLTextExtractor.firstMatch(pattern: #"thread-\d+-\d+-\d+\.html"#, in: url.absoluteString) != nil
        }
        let items = components.queryItems ?? []
        let mod = items.value(named: "mod")?.nilIfBlank
        if items.value(named: "tid")?.nilIfBlank != nil {
            return mod == nil || mod == "viewthread"
        }
        if items.value(named: "ptid")?.nilIfBlank != nil,
           items.value(named: "pid")?.nilIfBlank != nil,
           (items.value(named: "goto") == "findpost" || items.value(named: "mod") == "redirect") {
            return true
        }
        return HTMLTextExtractor.firstMatch(pattern: #"thread-\d+-\d+-\d+\.html"#, in: url.absoluteString) != nil
    }

    private static func userSpaceID(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = components.queryItems ?? []
            if items.value(named: "mod") == "space",
               items.value(named: "do") != "blog",
               let uid = items.value(named: "uid")?.nilIfBlank {
                return uid
            }
        }

        return HTMLTextExtractor.firstMatch(pattern: #"space-uid-(\d+)"#, in: url.absoluteString)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func privateMessageID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard items.value(named: "mod") == "spacecp",
              items.value(named: "ac") == "pm",
              items.value(named: "op") == "showmsg",
              let uid = items.value(named: "touid")?.nilIfBlank else {
            return nil
        }
        return uid
    }

    private static func messageCenterTab(from url: URL) -> MessageCenterTab? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard items.value(named: "mod") == "space" else { return nil }
        switch items.value(named: "do") {
        case "pm":
            return .privateMessages
        case "notice":
            return .notices
        default:
            return nil
        }
    }

    private static func blogRoute(from url: URL) -> (blogID: String, uid: String?)? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = components.queryItems ?? []
            if items.value(named: "do") == "blog",
               let blogID = (items.value(named: "id") ?? items.value(named: "blogid"))?.nilIfBlank {
                return (blogID, items.value(named: "uid")?.nilIfBlank)
            }
        }

        if let match = HTMLTextExtractor.firstMatch(pattern: #"blog-(\d+)-(\d+)"#, in: url.absoluteString),
           match.count >= 3 {
            return (match[2], match[1])
        }

        return nil
    }

    private static func isForumHomeURL(_ url: URL) -> Bool {
        guard url.host == YamiboDomain.baseURL.host else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        if path == "/" || path == "/index.php" {
            return true
        }
        guard path == "/forum.php" else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let mod = queryItems.value(named: "mod")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (mod == nil || mod?.isEmpty == true)
            && queryItems.value(named: "fid") == nil
            && queryItems.value(named: "tid") == nil
    }
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}

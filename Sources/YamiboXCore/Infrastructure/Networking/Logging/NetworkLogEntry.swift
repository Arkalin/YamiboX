import Foundation

public enum NetworkLogSource: String, Codable, CaseIterable, Sendable {
    case http
    case image
    case download
    case webDAV
    case update
    case webNavigation
    case webVerification
}

public struct NetworkLogError: Codable, Equatable, Sendable {
    public let category: String
    public let code: Int

    init(error: any Error) {
        let error = error as NSError
        // Domains outside this list may be supplied by arbitrary remote data.
        let knownDomains: Set<String> = [
            NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain,
            "NSOSStatusErrorDomain", "kCFErrorDomainCFNetwork", "WKErrorDomain",
            "Swift.CancellationError"
        ]
        category = knownDomains.contains(error.domain) ? error.domain : "OtherError"
        code = error.code
    }
}

public struct NetworkLogRedirect: Codable, Equatable, Sendable {
    public let fromURL: String?
    public let toURL: String?
    public let statusCode: Int?

    init(fromURL: String?, toURL: String?, statusCode: Int?) {
        self.fromURL = fromURL
        self.toURL = toURL
        self.statusCode = statusCode
    }
}

public struct NetworkLogEntry: Codable, Identifiable, Equatable, Sendable {
    public let formatVersion: Int
    public let id: UUID
    public let source: NetworkLogSource
    public let startedAt: Date
    public let duration: TimeInterval
    public let method: String
    public let initialURL: String
    public let finalURL: String?
    public let redirects: [NetworkLogRedirect]
    public let statusCode: Int?
    public let sentBytes: Int64?
    public let receivedBytes: Int64?
    public let error: NetworkLogError?
    public let truncated: Bool

    init(
        id: UUID, source: NetworkLogSource, startedAt: Date,
        duration: TimeInterval, method: String, initialURL: String,
        finalURL: String?, redirects: [NetworkLogRedirect], statusCode: Int?,
        sentBytes: Int64?, receivedBytes: Int64?, error: NetworkLogError?, truncated: Bool
    ) {
        formatVersion = 1
        self.id = id
        self.source = source
        self.startedAt = startedAt
        self.duration = duration
        self.method = method
        self.initialURL = initialURL
        self.finalURL = finalURL
        self.redirects = redirects
        self.statusCode = statusCode
        self.sentBytes = sentBytes
        self.receivedBytes = receivedBytes
        self.error = error
        self.truncated = truncated
    }
}

/// This produces the only URL representation accepted by the recorder.
enum NetworkLogRedactor {
    static let maximumURLBytes = 4_096
    private static let marker = "[REDACTED]"
    private static let numericKeys: Set<String> = [
        "fid", "tid", "pid", "ptid", "uid", "authorid", "page", "id", "blogid", "typeid",
        "mobile", "mycenter", "checkall", "inajax", "income", "ordertype", "reppost"
    ]
    private static let routeValues: [String: Set<String>] = [
        "mod": ["faq", "forum", "forumdisplay", "logging", "misc", "post", "redirect", "space", "spacecp", "tag", "viewthread"],
        "action": ["login", "logout", "rate", "reply", "viewratings", "viewvote", "votepoll"],
        "ac": ["blog", "comment", "credit", "favorite", "friend", "pm"],
        "do": ["blog", "favorite", "pm", "profile"],
        "op": ["add", "delete", "log", "send"],
        "type": ["all", "forum", "member", "reply", "thread"],
        "view": ["me"], "filter": ["typeid"], "goto": ["findpost"],
        "order": ["dateline"], "orderby": ["dateline"], "ascdesc": ["asc", "desc"],
        "handlekey": ["commentform", "favoriteforum", "favoritethread", "rate", "rateform"],
        "idtype": ["blogid"], "subop": ["view"], "srchtype": ["title"],
        "mobile": ["no"], "infloat": ["yes"], "comment": ["yes"],
        "commentsubmit": ["yes"], "ratesubmit": ["yes"], "searchsubmit": ["yes"]
    ]
    private static let forumScriptPaths: Set<String> = [
        "/forum.php", "/home.php", "/member.php", "/misc.php", "/search.php", "/plugin.php", "/api.php"
    ]
    private static let recognizableSensitiveKeys: Set<String> = [
        "formhash", "token", "password", "passwd", "pwd", "cookie", "authorization", "authkey",
        "sessionid", "seccode", "nox_jst", "srchtxt", "searchid", "referer"
    ]

    static func url(_ url: URL?, source: NetworkLogSource) -> (value: String?, truncated: Bool) {
        guard let url else { return (nil, false) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            return (marker, false)
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        var truncated = false
        let allowsForumRouteValues: Bool
        if source != .webDAV && source != .update,
           forumScriptPaths.contains(components.path.lowercased()),
           case let .success(environment) = YamiboForumEnvironment.launchConfiguration {
            allowsForumRouteValues = environment.isForumURL(url)
        } else {
            allowsForumRouteValues = false
        }
        if source == .webDAV {
            components.path = "/" + marker
        }
        components.queryItems = components.queryItems?.prefix(64).map { item in
            let key = item.name.lowercased()
            let name = numericKeys.contains(key) || routeValues[key] != nil || recognizableSensitiveKeys.contains(key)
                ? key : "[PARAMETER]"
            let value = item.value ?? ""
            let safeNumber = numericKeys.contains(key) && !value.isEmpty && value.utf8.count <= 20
                && value.utf8.allSatisfy { (48...57).contains($0) }
            let safeRoute = routeValues[key]?.contains(value) == true
            return URLQueryItem(name: name, value: allowsForumRouteValues && (safeNumber || safeRoute) ? value : marker)
        }
        if (URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.count ?? 0) > 64 {
            truncated = true
        }
        let result = limited(components.string ?? marker, maximumBytes: maximumURLBytes)
        return (result.value, truncated || result.truncated)
    }

    static func method(_ method: String?) -> String {
        let method = (method ?? "GET").uppercased()
        let knownMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "PROPFIND", "MKCOL", "MOVE", "COPY", "LOCK", "UNLOCK", "REPORT"]
        return knownMethods.contains(method) ? method : "OTHER"
    }

    private static func limited(_ value: String, maximumBytes: Int) -> (value: String, truncated: Bool) {
        guard value.utf8.count > maximumBytes else { return (value, false) }
        let suffix = "[TRUNCATED]"
        let bytes = value.utf8.prefix(maximumBytes - suffix.utf8.count)
        // A truncated scalar may decode as replacement text; trim it rather than
        // persisting invalid UTF-8 or exceeding the limit.
        var prefix = String(decoding: bytes, as: UTF8.self)
        while prefix.utf8.count > maximumBytes - suffix.utf8.count { prefix.removeLast() }
        return (prefix + suffix, true)
    }
}

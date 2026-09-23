import Foundation

/// The single enforcement point shared by session- and task-level transports.
enum YamiboNetworkPolicy {
    enum CookieStorageContext: Sendable {
        case standard
        /// A private, ephemeral jar used only for the current forum's login flow.
        case isolatedLogin
    }

    enum RedirectContext {
        case standard
        case forumPage
    }

    static var requiresRedirectProtection: Bool {
        YamiboForumEnvironment.current.restrictsRequestsToForumOrigin
    }

    static func cookieHeader(for url: URL, credentials: YamiboRequestCredentials, at date: Date) -> String {
        let environment = YamiboForumEnvironment.current
        guard !environment.restrictsRequestsToForumOrigin || environment.isForumURL(url) else { return "" }
        return credentials.cookies
            .filter { $0.matches(url, at: date) }
            .sorted {
                if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.domain < $1.domain
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func applyCredentials(
        _ credentials: YamiboRequestCredentials,
        to request: inout URLRequest,
        userAgent: String? = nil,
        handlesCookies: Bool? = nil,
        cookieStorageContext: CookieStorageContext = .standard
    ) {
        if YamiboForumEnvironment.current.restrictsRequestsToForumOrigin {
            // System cookie jars match domains, not origins (notably ignoring ports).
            // Only the login flow's private jar may receive Set-Cookie and carry
            // it to the next request. The redirect policy keeps it on this origin.
            request.httpShouldHandleCookies = cookieStorageContext == .isolatedLogin
                && handlesCookies == true
                && request.url.map(YamiboForumEnvironment.current.isForumURL) == true
        } else if let handlesCookies {
            request.httpShouldHandleCookies = handlesCookies
        }
        let header = request.url.map { cookieHeader(for: $0, credentials: credentials, at: .now) } ?? ""
        request.setValue(header.isEmpty ? nil : header, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent ?? credentials.userAgent, forHTTPHeaderField: "User-Agent")
    }

    static func redirectedRequest(
        _ request: URLRequest,
        from originalURL: URL?,
        context: RedirectContext = .standard
    ) -> URLRequest? {
        let environment = YamiboForumEnvironment.current
        if environment.restrictsRequestsToForumOrigin,
           let originalURL, environment.isForumURL(originalURL),
           request.url.map(environment.isForumURL) != true {
            return nil
        }
        if context == .forumPage {
            guard let url = request.url, ForumWebPagePolicy.isForumPage(url),
                  url.scheme?.lowercased() == environment.baseURL.scheme,
                  !ForumWebPagePolicy.requiresConfirmationToLoad(url), request.httpMethod == "GET" else {
                return nil
            }
        }
        return request
    }
}

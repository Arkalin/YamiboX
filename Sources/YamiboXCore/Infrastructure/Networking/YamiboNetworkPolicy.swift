import Foundation

enum YamiboNetworkPolicy {
    enum CookieStorageContext: Sendable {
        case standard
        case isolatedLogin
    }

    static var requiresRedirectProtection: Bool {
        YamiboForumEnvironment.current.restrictsRequestsToForumOrigin
    }

    static func cookieHeader(for url: URL, credentials: YamiboRequestCredentials, at date: Date) -> String {
        guard ForumOrigin(url: YamiboDomain.baseURL)?.contains(url) == true else { return "" }
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
        from originalURL: URL?
    ) -> URLRequest? {
        let environment = YamiboForumEnvironment.current
        if environment.restrictsRequestsToForumOrigin,
           let originalURL, environment.isForumURL(originalURL),
           request.url.map(environment.isForumURL) != true {
            return nil
        }
        return request
    }
}

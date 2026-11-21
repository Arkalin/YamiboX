import Foundation

struct ForumSessionCookieJar: Sendable {
    let session: URLSession
    let sessionStore: SessionStore

    func cookies() async -> [YamiboCookie] {
        let transportCookies = (session.configuration.httpCookieStorage?.cookies ?? [])
            .filter { YamiboDomain.isYamiboCookieDomain($0.domain) }
            .map { YamiboCookie($0) }
        let protection = ForumWAFResult(cookies: await sessionStore.load().cookies)
        var cookies = Dictionary(transportCookies.map { ($0.identity, $0) }, uniquingKeysWith: { _, newest in newest })
        for cookie in protection.cookies { cookies[cookie.identity] = cookie }
        return cookies.values.sorted { $0.identity < $1.identity }
    }

    func clear() {
        guard let storage = session.configuration.httpCookieStorage else { return }
        for cookie in storage.cookies ?? [] where YamiboDomain.containsYamiboDomain(cookie.domain) {
            storage.deleteCookie(cookie)
        }
    }
}

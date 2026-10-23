import Foundation

public extension SessionStoring {
    /// A private browser/login jar supplies its own storage ID. Native requests
    /// without a jar share the owning store's scoped Cookie identity.
    func forumRequestContext(
        snapshot: AccountSessionSnapshot,
        credentials: YamiboRequestCredentials? = nil,
        cookieStorageID: UUID? = nil
    ) -> ForumRequestContext {
        let supplied = credentials ?? snapshot.session.credentials
        let ownsClearance = supplied.userAgent == snapshot.session.credentials.userAgent
        let credentials = YamiboRequestCredentials(cookies: supplied.cookies.filter {
            ownsClearance || !YamiboCookie.isWAFCookie($0.name)
        }, userAgent: supplied.userAgent)
        let key = ForumSessionKey(
            origin: ForumOrigin(url: YamiboDomain.baseURL)!, scopeID: forumScopeID,
            generation: snapshot.generation, cookieStorageID: cookieStorageID ?? forumScopeID,
            userAgent: credentials.userAgent
        )
        return ForumRequestContext(
            key: key, credentials: credentials,
            validate: {
                guard await self.isCurrentGeneration(snapshot.generation) else { throw ForumWAFFailure.sessionInvalidated }
            },
            currentWAFCookies: {
                let current = try await self.snapshot()
                guard current.generation == snapshot.generation,
                      await self.isCurrentGeneration(snapshot.generation) else { throw ForumWAFFailure.sessionInvalidated }
                return ownsClearance ? current.session.cookies.filter { YamiboCookie.isWAFCookie($0.name) } : []
            },
            commitWAFCookies: { result in
                try Task.checkCancellation()
                guard ownsClearance else { return }
                do {
                    try await self.mergeWAFCookies(result.cookies, expectedGeneration: snapshot.generation, replacingCurrent: true)
                } catch {
                    try Task.checkCancellation()
                    guard await self.isCurrentGeneration(snapshot.generation) else { throw ForumWAFFailure.sessionInvalidated }
                    throw error
                }
            }
        )
    }
}

extension ForumRequestContext {
    func replacingCredentials(_ credentials: YamiboRequestCredentials) -> Self {
        let sameUA = credentials.userAgent == key.userAgent
        return Self(
            key: ForumSessionKey(origin: key.origin, scopeID: key.scopeID, generation: key.generation,
                                 cookieStorageID: key.cookieStorageID, userAgent: credentials.userAgent),
            credentials: YamiboRequestCredentials(cookies: credentials.cookies.filter {
                sameUA || !YamiboCookie.isWAFCookie($0.name)
            }, userAgent: credentials.userAgent), validate: validate,
            currentWAFCookies: { sameUA ? try await currentWAFCookies() : [] },
            commitWAFCookies: { result in if sameUA { try await commitWAFCookies(result) } }
        )
    }
}

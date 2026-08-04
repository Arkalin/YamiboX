import Foundation

public protocol SessionStoring: Sendable {
    func load() async -> SessionState
    func save(_ session: SessionState) async throws
    func updateCookie(_ cookie: String, isLoggedIn: Bool) async throws
    func updateWebSession(cookie: String, userAgent: String, isLoggedIn: Bool) async throws
    func updateWebSession(cookies: [YamiboCookie], userAgent: String) async throws
    func updateAccountUID(_ accountUID: String?) async throws
    func reset() async throws
}

public actor SessionStore: SessionStoring {
    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private let storage: UserDefaultsJSONStorage<SessionState>

    public init(defaults: UserDefaults = .standard, key: String = "yamibox.session") {
        self.storage = UserDefaultsJSONStorage(defaults: defaults, key: key) { error in
            YamiboLog.account.error("Failed to decode stored session state, resetting to logged-out state: \(error)")
        }
    }

    public func load() async -> SessionState {
        storage.load(default: SessionState())
    }

    public func save(_ session: SessionState) async throws {
        try storage.save(session)
        postChangeNotification()
    }

    public func updateCookie(_ cookie: String, isLoggedIn: Bool) async throws {
        var session = await load()
        let previousCookie = session.cookie
        session.cookie = cookie
        session.isLoggedIn = isLoggedIn
        if !isLoggedIn || cookie != previousCookie {
            session.accountUID = nil
        }
        session.lastUpdatedAt = .now
        try await save(session)
    }

    public func updateWebSession(cookie: String, userAgent: String, isLoggedIn _: Bool) async throws {
        try await updateWebSession(cookies: YamiboCookie.legacyCookies(from: cookie), userAgent: userAgent)
    }

    public func updateWebSession(cookies webCookies: [YamiboCookie], userAgent: String) async throws {
        var session = await load()
        let previousSession = session
        let previousAuthentication = session.authenticationCookie
        let incoming = canonicalCookies(webCookies.filter { !$0.isExpired() })
        let incomingAuthentication = incoming.first { $0.name == SessionState.authenticationCookieName }
        let preservesCurrentAuthentication = session.isLoggedIn && previousAuthentication != nil &&
            (incomingAuthentication == nil || incomingAuthentication?.value != previousAuthentication?.value)

        if preservesCurrentAuthentication, let previousAuthentication {
            session.cookies = canonicalCookies(
                incoming.filter { $0.name != SessionState.authenticationCookieName } + [previousAuthentication]
            )
        } else {
            session.cookies = incoming
        }
        session.userAgent = userAgent
        let resultingAuthentication = session.authenticationCookie
        session.isLoggedIn = resultingAuthentication != nil
        if resultingAuthentication?.value != previousAuthentication?.value {
            session.accountUID = nil
        }

        guard session.cookies != previousSession.cookies ||
            session.userAgent != previousSession.userAgent ||
            session.isLoggedIn != previousSession.isLoggedIn ||
            session.accountUID != previousSession.accountUID
        else {
            return
        }

        session.lastUpdatedAt = .now
        try await save(session)
    }

    private func canonicalCookies(_ cookies: [YamiboCookie]) -> [YamiboCookie] {
        var byIdentity: [String: YamiboCookie] = [:]
        for cookie in cookies {
            if let current = byIdentity[cookie.identity], current.capturedAt > cookie.capturedAt { continue }
            byIdentity[cookie.identity] = cookie
        }
        return byIdentity.values.sorted { $0.identity < $1.identity }
    }

    public func updateAccountUID(_ accountUID: String?) async throws {
        var session = await load()
        session.accountUID = accountUID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        session.lastUpdatedAt = .now
        try await save(session)
    }

    public func reset() async throws {
        try await save(SessionState())
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}

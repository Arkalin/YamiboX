import Foundation

public protocol SessionStoring: Sendable {
    func load() async -> SessionState
    func save(_ session: SessionState) async throws
    func updateCookie(_ cookie: String, isLoggedIn: Bool) async throws
    func updateWebSession(cookie: String, userAgent: String, isLoggedIn: Bool) async throws
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
        var session = await load()
        let previousSession = session
        let previousAuthenticationValue = SessionState.authenticationCookieValue(in: session.cookie)
        let webAuthenticationValue = SessionState.authenticationCookieValue(in: cookie)
        let hasCurrentAuthentication = session.isLoggedIn && previousAuthenticationValue != nil

        if hasCurrentAuthentication,
           webAuthenticationValue != previousAuthenticationValue {
            return
        }

        session.cookie = cookie
        session.userAgent = userAgent
        session.isLoggedIn = webAuthenticationValue != nil
        if webAuthenticationValue == nil || webAuthenticationValue != previousAuthenticationValue {
            session.accountUID = nil
        }

        guard session.cookie != previousSession.cookie ||
            session.userAgent != previousSession.userAgent ||
            session.isLoggedIn != previousSession.isLoggedIn ||
            session.accountUID != previousSession.accountUID
        else {
            return
        }

        session.lastUpdatedAt = .now
        try await save(session)
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

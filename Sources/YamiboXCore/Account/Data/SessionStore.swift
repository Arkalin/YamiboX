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
    public nonisolated let accountStore: AccountStore?
    public nonisolated let accountOperations: AccountOperationGate
    public nonisolated var changeID: String { accountStore?.broadcaster.changeID ?? changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> {
        accountStore?.broadcaster.changes() ?? changeBroadcaster.changes()
    }

    private let storage: UserDefaultsJSONStorage<SessionState>?
    private var generation = UUID()
    private var transition: UUID?

    public init(accountStore: AccountStore = .shared) {
        self.accountStore = accountStore
        accountOperations = accountStore.operations
        storage = nil
    }

    public init(defaults: UserDefaults, key: String = "yamibox.session") {
        accountStore = nil
        accountOperations = AccountOperationGate()
        self.storage = UserDefaultsJSONStorage(defaults: defaults, key: key) { error in
            YamiboLog.account.error("Failed to decode stored session state, resetting to logged-out state: \(error)")
        }
    }

    public func load() async -> SessionState {
        do { return try await snapshot().session }
        catch {
            YamiboLog.account.error("Unable to read account session: \(error)")
            return SessionState()
        }
    }

    public func snapshot() async throws -> AccountSessionSnapshot {
        if let accountStore { return try await accountStore.snapshot() }
        return AccountSessionSnapshot(session: storage?.load(default: SessionState()) ?? SessionState(), generation: generation)
    }

    public func isCurrentGeneration(_ expected: UUID) async -> Bool {
        if let accountStore { return await accountStore.isCurrent(expected) }
        return generation == expected && transition == nil
    }

    public func save(_ session: SessionState) async throws {
        try await save(session, expectedGeneration: nil)
    }

    public func save(_ session: SessionState, expectedGeneration: UUID?) async throws {
        if let accountStore {
            try await accountStore.saveSession(session, expected: expectedGeneration)
            return
        }
        guard transition == nil else { throw CancellationError() }
        if let expectedGeneration, generation != expectedGeneration { throw CancellationError() }
        if storage?.load(default: SessionState()).authenticationCookie?.value != session.authenticationCookie?.value {
            generation = UUID()
        }
        try storage?.save(session)
        postChangeNotification()
    }

    public func updateCookie(_ cookie: String, isLoggedIn: Bool) async throws {
        let snapshot = try await snapshot()
        var session = snapshot.session
        let previousCookie = session.cookie
        session.cookie = cookie
        session.isLoggedIn = isLoggedIn
        if !isLoggedIn || cookie != previousCookie {
            session.accountUID = nil
        }
        session.lastUpdatedAt = .now
        try await save(session, expectedGeneration: snapshot.generation)
    }

    public func updateWebSession(cookie: String, userAgent: String, isLoggedIn _: Bool) async throws {
        try await updateWebSession(cookies: YamiboCookie.legacyCookies(from: cookie), userAgent: userAgent)
    }

    public func updateWebSession(cookies webCookies: [YamiboCookie], userAgent: String) async throws {
        try await updateWebSession(cookies: webCookies, userAgent: userAgent, expectedGeneration: nil)
    }

    public func updateWebSession(cookies webCookies: [YamiboCookie], userAgent: String, expectedGeneration: UUID?) async throws {
        let snapshot = try await snapshot()
        if let expectedGeneration, expectedGeneration != snapshot.generation { throw CancellationError() }
        var session = snapshot.session
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
        try await save(session, expectedGeneration: snapshot.generation)
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
        try await updateAccountUID(accountUID, expectedGeneration: nil)
    }

    func updateAccountUID(_ accountUID: String?, expectedGeneration: UUID?) async throws {
        let snapshot = try await snapshot()
        if let expectedGeneration, expectedGeneration != snapshot.generation { throw CancellationError() }
        var session = snapshot.session
        session.accountUID = accountUID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        session.lastUpdatedAt = .now
        try await save(session, expectedGeneration: snapshot.generation)
    }

    public func reset() async throws {
        if let accountStore {
            try await accountStore.clearCurrent(removingAccount: false)
            return
        }
        try await save(SessionState())
    }

    public func beginIdentityTransition() async throws -> UUID {
        if let accountStore { return try await accountStore.beginTransition() }
        guard transition == nil else { throw AccountSwitchError.busy }
        generation = UUID()
        transition = generation
        return generation
    }

    public func endIdentityTransition(_ token: UUID) async {
        if let accountStore { await accountStore.endTransition(token); return }
        guard transition == token else { return }
        transition = nil
        generation = UUID()
        postChangeNotification()
    }

    func commitAccount(_ session: SessionState, profile: YamiboProfile, token: UUID) async throws {
        if let accountStore {
            try await accountStore.activate(session: session, profile: profile, token: token)
        } else {
            guard transition == token else { throw CancellationError() }
            try storage?.save(session)
        }
    }

    func commitSignOut(token: UUID, removesAccount: Bool) async throws {
        if let accountStore {
            try await accountStore.clearCurrent(removingAccount: removesAccount, token: token)
        } else {
            guard transition == token else { throw CancellationError() }
            try storage?.save(SessionState())
        }
    }

    func resetAllAccounts(token: UUID) async throws {
        if let accountStore { try await accountStore.resetAll(token: token) }
        else { try await commitSignOut(token: token, removesAccount: true) }
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}

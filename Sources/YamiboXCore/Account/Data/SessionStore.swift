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
    public static let didChangeNotification = Notification.Name("yamibox.sessionStore.didChange")
    public static let changeIDUserInfoKey = "changeID"

    public nonisolated let changeID = UUID().uuidString

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = "yamibox.session") {
        self.defaults = defaults
        self.key = key
    }

    public func load() async -> SessionState {
        guard let data = defaults.data(forKey: key) else { return SessionState() }
        do {
            return try decoder.decode(SessionState.self, from: data)
        } catch {
            YamiboLog.account.error("Failed to decode stored session state, resetting to logged-out state: \(error)")
            return SessionState()
        }
    }

    public func save(_ session: SessionState) async throws {
        do {
            let data = try encoder.encode(session)
            defaults.set(data, forKey: key)
            postChangeNotification()
        } catch {
            throw YamiboError.persistenceFailed(error.localizedDescription)
        }
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
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.changeIDUserInfoKey: changeID]
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

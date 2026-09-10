import Foundation

/// One atomic document owns saved credentials and both current-account projections.
public actor AccountStore {
    public static let shared = AccountStore(persistence: KeychainAccountVaultPersistence(), legacyDefaults: .standard)
    nonisolated let broadcaster = StoreChangeBroadcaster()
    public nonisolated let operations = AccountOperationGate()
    private let persistence: any AccountVaultPersisting
    private let legacyDefaults: UserDefaults?
    private var document: Document?
    private var generation = UUID()
    private var transition: UUID?

    private struct Record: Codable {
        var profile: YamiboProfile
        var session: SessionState?
        var lastUsedAt: Date
    }

    private struct Document: Codable {
        var current = SessionState()
        var profile: YamiboProfile?
        var accounts: [String: Record] = [:]
    }

    init(persistence: any AccountVaultPersisting, legacyDefaults: UserDefaults? = nil) {
        self.persistence = persistence
        self.legacyDefaults = legacyDefaults
    }

    public static func temporary() -> AccountStore {
        AccountStore(persistence: MemoryAccountVaultPersistence())
    }

    public func accounts() throws -> [SavedAccount] {
        let document = try expireCredentials()
        return document.accounts.values.map { record in
            SavedAccount(
                profile: record.profile,
                lastUsedAt: record.lastUsedAt,
                isCurrent: document.current.isLoggedIn && document.current.accountUID == record.profile.uid,
                requiresLogin: record.session?.hasValidAuthenticationCookie != true
            )
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
            return $0.id < $1.id
        }
    }

    func savedSession(uid: String) throws -> SessionState? {
        guard let record = try loadDocument().accounts[uid] else { throw AccountSwitchError.accountMissing }
        return record.session
    }

    func snapshot() throws -> AccountSessionSnapshot {
        let document = try expireCredentials()
        return AccountSessionSnapshot(session: document.current, generation: generation)
    }

    func profile() throws -> YamiboProfile? { try loadDocument().profile }

    func isCurrent(_ expected: UUID) -> Bool { generation == expected && transition == nil }

    func saveSession(_ session: SessionState, expected: UUID? = nil) throws {
        try check(expected)
        var next = try loadDocument()
        let identityChanged = next.current.authenticationCookie?.value != session.authenticationCookie?.value
        if identityChanged || (session.accountUID != nil && next.profile?.uid != session.accountUID) {
            next.profile = nil
        }
        next.current = session
        archiveCurrent(in: &next)
        try persist(next)
        if identityChanged { generation = UUID() }
        broadcaster.post()
    }

    func saveProfile(_ profile: YamiboProfile?, expected: UUID? = nil) throws {
        try check(expected)
        var next = try loadDocument()
        if let profile {
            guard next.current.isLoggedIn,
                  next.current.accountUID == nil || next.current.accountUID == profile.uid else {
                throw AccountSwitchError.identityMismatch
            }
            next.current.accountUID = profile.uid.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        next.profile = profile
        archiveCurrent(in: &next)
        try persist(next)
        broadcaster.post()
    }

    func beginTransition() throws -> UUID {
        guard transition == nil else { throw AccountSwitchError.busy }
        _ = try loadDocument()
        generation = UUID()
        transition = generation
        return generation
    }

    func endTransition(_ token: UUID) {
        guard transition == token else { return }
        transition = nil
        generation = UUID()
        broadcaster.post()
    }

    func activate(session: SessionState, profile: YamiboProfile, token: UUID) throws {
        guard transition == token else { throw CancellationError() }
        let uid = profile.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, session.isLoggedIn, session.hasValidAuthenticationCookie,
              session.accountUID == uid else { throw AccountSwitchError.identityMismatch }
        var next = try loadDocument()
        archiveCurrent(in: &next)
        next.current = session
        next.profile = profile
        next.accounts[uid] = Record(profile: profile, session: session, lastUsedAt: .now)
        try persist(next)
    }

    func invalidate(uid: String) throws {
        try check(nil)
        var next = try loadDocument()
        next.accounts[uid]?.session = nil
        try persist(next)
        broadcaster.post()
    }

    func clearCurrent(removingAccount: Bool, token: UUID? = nil) throws {
        if let token {
            guard transition == token else { throw CancellationError() }
        } else {
            try check(nil)
        }
        var next = try loadDocument()
        archiveCurrent(in: &next)
        if let uid = next.current.accountUID {
            if removingAccount { next.accounts[uid] = nil }
            else { next.accounts[uid]?.session = nil }
        }
        next.current = SessionState()
        next.profile = nil
        try persist(next)
        if token == nil {
            generation = UUID()
            broadcaster.post()
        }
    }

    func remove(uid: String) throws {
        try check(nil)
        var next = try loadDocument()
        guard next.current.accountUID != uid else { throw AccountSwitchError.busy }
        next.accounts[uid] = nil
        try persist(next)
        broadcaster.post()
    }

    func resetAll(token: UUID) throws {
        guard transition == token else { throw CancellationError() }
        // Keep an empty vault as the migration tombstone, including after a reset.
        try persist(Document())
        clearLegacyData()
    }

    private func check(_ expected: UUID?) throws {
        guard transition == nil else { throw CancellationError() }
        if let expected, expected != generation { throw CancellationError() }
    }

    private func expireCredentials() throws -> Document {
        var next = try loadDocument()
        guard transition == nil else { return next }
        var changed = false
        for uid in Array(next.accounts.keys) {
            if let session = next.accounts[uid]?.session, !session.hasValidAuthenticationCookie {
                next.accounts[uid]?.session = nil
                changed = true
            }
        }
        let currentExpired = next.current.isLoggedIn && !next.current.hasValidAuthenticationCookie
        if currentExpired {
            next.current = SessionState()
            next.profile = nil
            changed = true
        }
        if changed {
            try persist(next)
            if currentExpired { generation = UUID() }
            broadcaster.post()
        }
        return next
    }

    private func archiveCurrent(in document: inout Document) {
        guard document.current.isLoggedIn, let uid = document.current.accountUID,
              let profile = document.profile, !uid.isEmpty, profile.uid == uid else { return }
        document.accounts[uid] = Record(
            profile: profile,
            session: document.current,
            lastUsedAt: document.accounts[uid]?.lastUsedAt ?? .now
        )
    }

    private func loadDocument() throws -> Document {
        if let document { return document }
        if let data = try persistence.read() {
            let decoded = try JSONDecoder().decode(Document.self, from: data)
            document = decoded
            clearLegacyData()
            return decoded
        }
        var migrated = Document()
        if let data = legacyDefaults?.data(forKey: "yamibox.session") {
            migrated.current = try JSONDecoder().decode(SessionState.self, from: data)
        }
        if let data = legacyDefaults?.data(forKey: "yamibox.profile") {
            let profile = try JSONDecoder().decode(YamiboProfile.self, from: data)
            if migrated.current.isLoggedIn,
               migrated.current.accountUID == nil || migrated.current.accountUID == profile.uid {
                migrated.profile = profile
            }
        }
        archiveCurrent(in: &migrated)
        try persist(migrated)
        clearLegacyData()
        return migrated
    }

    private func persist(_ next: Document) throws {
        try persistence.write(JSONEncoder().encode(next))
        document = next
    }

    private func clearLegacyData() {
        legacyDefaults?.removeObject(forKey: "yamibox.session")
        legacyDefaults?.removeObject(forKey: "yamibox.profile")
    }
}

/// Actor reentrancy must not permit a second account operation during network awaits.
public actor AccountOperationGate {
    private var owner: UUID?

    public func acquire() throws -> UUID {
        guard owner == nil else { throw AccountSwitchError.busy }
        let token = UUID()
        owner = token
        return token
    }

    public func release(_ token: UUID) {
        if owner == token { owner = nil }
    }

    public func checkOwner(_ token: UUID) throws {
        guard owner == token else { throw CancellationError() }
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let token = try acquire()
        defer { release(token) }
        return try await operation()
    }
}

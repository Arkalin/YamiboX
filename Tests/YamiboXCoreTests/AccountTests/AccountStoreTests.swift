import Foundation
import Security
import Testing
@testable import YamiboXCore

@Suite("Saved accounts")
struct AccountStoreTests {
    @Test func migratesLegacySessionOnceAndPreservesCookieMetadata() async throws {
        let suite = "accounts-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = TestAccountVaultPersistence()
        let session = accountSession("1")
        let profile = accountProfile("1")
        defaults.set(try JSONEncoder().encode(session), forKey: "yamibox.session")
        defaults.set(try JSONEncoder().encode(profile), forKey: "yamibox.profile")
        let store = AccountStore(persistence: persistence, legacyDefaults: UserDefaults(suiteName: suite))

        #expect(try await store.snapshot().session == session)
        #expect(try await store.profile() == profile)
        #expect(try await store.accounts().map(\.id) == ["1"])
        #expect(defaults.data(forKey: "yamibox.session") == nil)
        #expect(defaults.data(forKey: "yamibox.profile") == nil)

        defaults.set(try JSONEncoder().encode(accountSession("2")), forKey: "yamibox.session")
        let reopened = AccountStore(persistence: persistence, legacyDefaults: UserDefaults(suiteName: suite))
        #expect(try await reopened.snapshot().session == session)
        #expect(try await reopened.accounts().map(\.id) == ["1"])
        #expect(defaults.data(forKey: "yamibox.session") == nil)
    }

    @Test func migrationFailureDoesNotDeleteLegacyCredentialsOrOverwriteUnreadableVault() async throws {
        let suite = "accounts-failed-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = try JSONEncoder().encode(accountSession("1"))
        defaults.set(old, forKey: "yamibox.session")
        defaults.set(try JSONEncoder().encode(accountProfile("1")), forKey: "yamibox.profile")
        let persistence = TestAccountVaultPersistence()
        persistence.failWrites = true
        let store = AccountStore(persistence: persistence, legacyDefaults: UserDefaults(suiteName: suite))
        await #expect(throws: AccountSwitchError.secureStorage(-1)) { try await store.snapshot() }
        #expect(defaults.data(forKey: "yamibox.session") == old)
        #expect(try persistence.read() == nil)
        persistence.failWrites = false
        persistence.failReads = true
        await #expect(throws: AccountSwitchError.secureStorage(-2)) { try await store.saveSession(accountSession("2")) }
        #expect(defaults.data(forKey: "yamibox.session") == old)
        persistence.failReads = false
        #expect(try await store.snapshot().session.accountUID == "1")
        #expect(defaults.data(forKey: "yamibox.session") == nil)
    }

    @Test func missingUIDIsNotArchivedUntilProfileIsVerified() async throws {
        let store = AccountStore.temporary()
        var session = accountSession("1")
        session.accountUID = nil
        try await store.saveSession(session)
        #expect(try await store.accounts().isEmpty)
        #expect(try await store.snapshot().session.hasValidAuthenticationCookie)
        let baseline = try await store.snapshot()
        try await store.saveProfile(accountProfile("1"), expected: baseline.generation)
        #expect(try await store.accounts().map(\.id) == ["1"])
        #expect(try await store.snapshot().session.accountUID == "1")
    }

    @Test func switchingRoundTripDeduplicatesUIDAndRestoresProjections() async throws {
        let persistence = TestAccountVaultPersistence()
        let store = AccountStore(persistence: persistence)
        let sessions = SessionStore(accountStore: store)
        let profiles = YamiboProfileStore(accountStore: store)
        try await activateAccount("1", in: store)
        let originalGeneration = try await sessions.snapshot().generation
        try await activateAccount("2", in: store)
        #expect(await profiles.load()?.uid == "2")
        try await activateAccount("1", in: store, username: "renamed")
        let accounts = try await store.accounts()
        #expect(accounts.map(\.id) == ["1", "2"])
        #expect(accounts.first?.profile.username == "renamed")
        #expect(accounts.first?.isCurrent == true)
        #expect(accounts.last?.isCurrent == false)
        #expect(!(await sessions.isCurrentGeneration(originalGeneration)))
        let restored = AccountStore(persistence: persistence)
        #expect(try await restored.snapshot().session == sessions.load())
        #expect(try await restored.profile()?.username == "renamed")
    }

    @Test func failedCommitLeavesOriginalAccountAndProfileIntact() async throws {
        let persistence = TestAccountVaultPersistence()
        let store = AccountStore(persistence: persistence)
        try await activateAccount("1", in: store)
        let old = try await store.snapshot()
        let token = try await store.beginTransition()
        persistence.failWrites = true
        await #expect(throws: AccountSwitchError.secureStorage(-1)) {
            try await store.activate(session: accountSession("2"), profile: accountProfile("2"), token: token)
        }
        await store.endTransition(token)
        #expect(try await store.snapshot().session == old.session)
        #expect(try await store.profile()?.uid == "1")
        #expect(try await store.accounts().count == 1)
        persistence.failWrites = false
        #expect(try await AccountStore(persistence: persistence).snapshot().session == old.session)
    }

    @Test func staleProfileAndCookieCallbacksCannotWriteAcrossTransitionIncludingABA() async throws {
        let store = AccountStore.temporary()
        let sessions = SessionStore(accountStore: store)
        let profiles = YamiboProfileStore(accountStore: store)
        try await activateAccount("1", in: store)
        let old = try await sessions.snapshot()
        let token = try await sessions.beginIdentityTransition()
        await #expect(throws: CancellationError.self) {
            try await profiles.save(accountProfile("1", username: "stale"), expectedGeneration: old.generation)
        }
        try await sessions.commitAccount(accountSession("2"), profile: accountProfile("2"), token: token)
        await sessions.endIdentityTransition(token)
        try await activateAccount("1", in: store)
        await #expect(throws: CancellationError.self) {
            try await sessions.updateWebSession(cookies: accountSession("2").cookies, userAgent: "stale", expectedGeneration: old.generation)
        }
        #expect(await sessions.load().userAgent == "account-agent-1")
        #expect(await profiles.load()?.username == "user-1")
    }

    @Test func expiredLoginAndExplicitLogoutHaveDifferentRetention() async throws {
        let store = AccountStore.temporary()
        try await activateAccount("1", in: store)
        try await activateAccount("2", in: store)
        try await store.clearCurrent(removingAccount: false)
        #expect(try await store.snapshot().session == SessionState())
        #expect(try await store.accounts().count == 2)
        #expect(try await store.accounts().first { $0.id == "2" }?.requiresLogin == true)
        #expect(try await store.savedSession(uid: "2") == nil)
        try await activateAccount("1", in: store)
        let token = try await store.beginTransition()
        try await store.clearCurrent(removingAccount: true, token: token)
        await store.endTransition(token)
        #expect(try await store.accounts().map(\.id) == ["2"])
        #expect(try await store.profile() == nil)
        #expect(try await store.snapshot().session.accountUID == nil)
    }

    @Test func removingInactiveAccountDoesNotTouchCurrentIdentity() async throws {
        let store = AccountStore.temporary()
        try await activateAccount("1", in: store)
        try await activateAccount("2", in: store)
        let snapshot = try await store.snapshot()
        try await store.remove(uid: "1")
        #expect(try await store.snapshot().session == snapshot.session)
        #expect(await store.isCurrent(snapshot.generation))
        #expect(try await store.accounts().map(\.id) == ["2"])
    }

    @Test func resetPersistsEmptyMigrationTombstone() async throws {
        let persistence = TestAccountVaultPersistence()
        let store = AccountStore(persistence: persistence)
        try await activateAccount("1", in: store)
        try await activateAccount("2", in: store)
        let token = try await store.beginTransition()
        try await store.resetAll(token: token)
        await store.endTransition(token)
        let reopened = AccountStore(persistence: persistence)
        #expect(try await reopened.accounts().isEmpty)
        #expect(try await reopened.snapshot().session == SessionState())
        #expect(try persistence.read() != nil)
    }

    @Test func gateRejectsOverlappingOperationsAndOldLeaseCannotReleaseNewOwner() async throws {
        let gate = AccountOperationGate()
        let first = try await gate.acquire()
        await #expect(throws: AccountSwitchError.busy) { try await gate.run { true } }
        await gate.release(first)
        let second = try await gate.acquire()
        await gate.release(first)
        await #expect(throws: AccountSwitchError.busy) { try await gate.acquire() }
        await #expect(throws: CancellationError.self) { try await gate.checkOwner(first) }
        await gate.release(second)
        #expect(try await gate.run { 42 } == 42)
    }

    @Test(.enabled(if: hasKeychainEntitlement, "The unsigned, unhosted test runner has no Keychain entitlement"))
    func keychainRoundTripIsLocalAndDeviceOnly() throws {
        let service = "com.arkalin.YamiboX.test.accounts.\(UUID())"
        let persistence = KeychainAccountVaultPersistence(service: service)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "vault"]
        defer { SecItemDelete(query as CFDictionary) }
        #expect(try persistence.read() == nil)
        try persistence.write(Data("first".utf8))
        try persistence.write(Data("second".utf8))
        #expect(try persistence.read() == Data("second".utf8))
        var attributes: CFTypeRef?
        #expect(SecItemCopyMatching(query.merging([kSecReturnAttributes as String: true]) { _, new in new } as CFDictionary, &attributes) == errSecSuccess)
        let values = try #require(attributes as? [String: Any])
        #expect(values[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(values[kSecAttrSynchronizable as String] as? Bool != true)
    }

    private static var hasKeychainEntitlement: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.arkalin.YamiboX.test.entitlement-probe"]
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecMissingEntitlement
    }

    @Test func checkInUsesUIDAfterCookieRotationAndMigratesLegacyHash() async throws {
        let suite = "account-check-in-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = YamiboCheckInStore(defaults: defaults)
        var legacy = accountSession("1")
        legacy.accountUID = nil
        await store.markCheckedIn(session: legacy)
        #expect(!(await store.needsCheckIn(session: accountSession("1"))))
        var rotated = accountSession("2")
        rotated.accountUID = "1"
        #expect(!(await store.needsCheckIn(session: rotated)))
        #expect(await store.needsCheckIn(session: accountSession("2")))
    }
}

func accountSession(_ uid: String) -> SessionState {
    SessionState(cookies: [
        YamiboCookie(name: SessionState.authenticationCookieName, value: "auth-\(uid)", domain: YamiboDomain.forumHost,
                     expiresAt: Date(timeIntervalSince1970: 4_000_000_000), capturedAt: Date(timeIntervalSince1970: 1_000)),
        YamiboCookie(name: "salt", value: uid, domain: ".yamibo.com", path: "/home.php",
                     expiresAt: Date(timeIntervalSince1970: 4_000_000_000), capturedAt: Date(timeIntervalSince1970: 1_000),
                     isSecure: true, isHTTPOnly: true, sameSitePolicy: "Lax")
    ], userAgent: "account-agent-\(uid)", isLoggedIn: true, accountUID: uid)
}

func accountProfile(_ uid: String, username: String? = nil) -> YamiboProfile {
    YamiboProfile(uid: uid, username: username ?? "user-\(uid)", userGroup: "member", points: 1, partner: 2, totalPoints: 3)
}

func activateAccount(_ uid: String, in store: AccountStore, username: String? = nil) async throws {
    let token = try await store.beginTransition()
    do { try await store.activate(session: accountSession(uid), profile: accountProfile(uid, username: username), token: token) }
    catch { await store.endTransition(token); throw error }
    await store.endTransition(token)
}

final class TestAccountVaultPersistence: AccountVaultPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var readFailure = false
    private var writeFailure = false
    var failReads: Bool {
        get { lock.withLock { readFailure } }
        set { lock.withLock { readFailure = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { writeFailure } }
        set { lock.withLock { writeFailure = newValue } }
    }
    func read() throws -> Data? {
        try lock.withLock {
            if readFailure { throw AccountSwitchError.secureStorage(-2) }
            return data
        }
    }
    func write(_ data: Data) throws {
        try lock.withLock {
            if writeFailure { throw AccountSwitchError.secureStorage(-1) }
            self.data = data
        }
    }
}

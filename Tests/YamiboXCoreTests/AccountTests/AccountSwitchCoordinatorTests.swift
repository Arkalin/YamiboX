import Foundation
import Testing
@testable import YamiboXCore

@Suite("Account switching")
struct AccountSwitchCoordinatorTests {
    @Test func verifiesBeforeCommitAndKeepsBothAccounts() async throws {
        let fixture = AccountSwitchFixture()
        try await fixture.seed()
        let validation = AccountValidationBarrier()
        let task = Task {
            try await fixture.coordinator.switchAccount(uid: "2") { session in
                await validation.wait()
                return AuthenticatedAccount(session: session, profile: accountProfile("2"))
            }
        }
        await validation.waitUntilStarted()
        #expect(await fixture.sessions.load().accountUID == "1")
        #expect(await fixture.probe.count == 0)
        await #expect(throws: AccountSwitchError.busy) { try await fixture.coordinator.switchAccount(uid: "2") }
        await #expect(throws: AccountSwitchError.busy) { try await fixture.coordinator.signOut() }
        await validation.release()
        try await task.value
        #expect(await fixture.sessions.load().accountUID == "2")
        #expect(await fixture.profiles.load()?.uid == "2")
        #expect(try await fixture.coordinator.accounts().count == 2)
        #expect(await fixture.probe.count == 1)
    }

    @Test func networkFailureAndWrongUIDDoNotChangeOriginalSession() async throws {
        let fixture = AccountSwitchFixture()
        try await fixture.seed()
        let original = await fixture.sessions.load()
        await #expect(throws: URLError.self) {
            try await fixture.coordinator.switchAccount(uid: "2") { _ in throw URLError(.notConnectedToInternet) }
        }
        await #expect(throws: AccountSwitchError.identityMismatch) {
            try await fixture.coordinator.switchAccount(uid: "2") { session in
                AuthenticatedAccount(session: session, profile: accountProfile("3"))
            }
        }
        #expect(await fixture.sessions.load() == original)
        #expect(await fixture.profiles.load()?.uid == "1")
        #expect(await fixture.probe.count == 0)
        #expect(try await fixture.store.savedSession(uid: "2") != nil)
    }

    @Test func serverExpiredSessionClearsOnlyTargetCredentials() async throws {
        let fixture = AccountSwitchFixture()
        try await fixture.seed()
        await #expect(throws: YamiboError.notAuthenticated) {
            try await fixture.coordinator.switchAccount(uid: "2") { _ in throw YamiboError.notAuthenticated }
        }
        #expect(await fixture.sessions.load().accountUID == "1")
        #expect(try await fixture.store.savedSession(uid: "2") == nil)
        #expect(try await fixture.coordinator.accounts().first { $0.id == "2" }?.requiresLogin == true)
        #expect(await fixture.probe.count == 0)
    }

    @Test func cancelledValidationNeverCommitsEvenWhenTransportFinishes() async throws {
        let fixture = AccountSwitchFixture()
        try await fixture.seed()
        let validation = AccountValidationBarrier()
        let task = Task {
            try await fixture.coordinator.switchAccount(uid: "2") { session in
                await validation.wait()
                return AuthenticatedAccount(session: session, profile: accountProfile("2"))
            }
        }
        await validation.waitUntilStarted()
        task.cancel()
        await validation.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.sessions.load().accountUID == "1")
        #expect(await fixture.probe.count == 0)
        #expect(try await fixture.sessions.accountOperations.run { true })
    }

    @Test func cancelledLoginLeaseAndWrongAccountCannotActivate() async throws {
        let fixture = AccountSwitchFixture()
        try await fixture.seed()
        let lease = try await fixture.sessions.accountOperations.acquire()
        await #expect(throws: AccountSwitchError.identityMismatch) {
            try await fixture.coordinator.activateLogin(
                session: accountSession("3"), profile: accountProfile("3"), expectedUID: "2", lease: lease
            )
        }
        await fixture.sessions.accountOperations.release(lease)
        await #expect(throws: CancellationError.self) {
            try await fixture.coordinator.activateLogin(
                session: accountSession("2"), profile: accountProfile("2"), expectedUID: "2", lease: lease
            )
        }
        #expect(await fixture.sessions.load().accountUID == "1")
        #expect(await fixture.probe.count == 0)
    }

    @Test func signOutRemovesOnlyCurrentAccountAndDoesNotAutoSelectAnother() async throws {
        let fixture = AccountSwitchFixture()
        try await fixture.seed()
        try await fixture.coordinator.signOut()
        #expect(try await fixture.coordinator.accounts().map(\.id) == ["2"])
        #expect(await fixture.sessions.load() == SessionState())
        #expect(await fixture.profiles.load() == nil)
        try await fixture.coordinator.removeAccount(uid: "2")
        #expect(try await fixture.coordinator.accounts().isEmpty)
    }

    @Test func snapshotsCreatedDuringHandoffCannotBecomeValidAfterIt() async throws {
        let fixture = AccountSwitchFixture()
        try await fixture.seed()
        let token = try await fixture.sessions.beginIdentityTransition()
        let transient = try await fixture.sessions.snapshot()
        try await fixture.sessions.commitAccount(accountSession("2"), profile: accountProfile("2"), token: token)
        await fixture.sessions.endIdentityTransition(token)
        #expect(!(await fixture.sessions.isCurrentGeneration(transient.generation)))
        let current = try await fixture.sessions.snapshot()
        #expect(await fixture.sessions.isCurrentGeneration(current.generation))
    }
}

private struct AccountSwitchFixture {
    let store = AccountStore.temporary()
    let sessions: SessionStore
    let profiles: YamiboProfileStore
    let probe = AccountTransitionProbe()
    let coordinator: AccountSwitchCoordinator

    init() {
        let sessions = SessionStore(accountStore: store)
        let profiles = YamiboProfileStore(accountStore: store)
        self.sessions = sessions
        self.profiles = profiles
        let probe = probe
        coordinator = AccountSwitchCoordinator(
            sessionStore: sessions, profileStore: profiles,
            makeService: { YamiboAccountService(sessionStore: sessions, profileStore: profiles) },
            transition: { commit in
                await probe.record()
                let token = try await sessions.beginIdentityTransition()
                do { try await commit(token) }
                catch { await sessions.endIdentityTransition(token); throw error }
                await sessions.endIdentityTransition(token)
            }
        )
    }

    func seed() async throws {
        try await activateAccount("2", in: store)
        try await activateAccount("1", in: store)
    }
}

private actor AccountTransitionProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

actor AccountValidationBarrier {
    private var started = false
    private var released = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var workWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        readyWaiters.forEach { $0.resume() }
        readyWaiters.removeAll()
        if !released { await withCheckedContinuation { workWaiters.append($0) } }
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { readyWaiters.append($0) } }
    }

    func release() {
        released = true
        workWaiters.forEach { $0.resume() }
        workWaiters.removeAll()
    }
}

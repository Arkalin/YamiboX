import Foundation
import Testing
import YamiboXTestSupport
@testable import YamiboXCore

@Suite("Message unread workflow", .timeLimit(.minutes(1)))
@MainActor
struct MessageUnreadWorkflowTests {
    @Test func startupForegroundCooldownAndManualRefresh() async throws {
        try await withFixture { fixture in
            await fixture.workflow.appDidBecomeActive()
            #expect(fixture.workflow.totalCount == 5)
            await fixture.workflow.appDidBecomeActive()
            #expect(await fixture.loader.callCount == 1)

            fixture.workflow.appDidEnterBackground()
            fixture.clock.advance(29)
            await fixture.workflow.appDidBecomeActive()
            #expect(await fixture.loader.callCount == 1)
            fixture.clock.advance(1)
            await fixture.workflow.appDidBecomeActive()
            #expect(await fixture.loader.callCount == 2)
            await fixture.workflow.refresh(force: true)
            #expect(await fixture.loader.callCount == 3)
        }
    }

    @Test func concurrentChecksShareOneRequest() async throws {
        try await withFixture { fixture in
            await fixture.loader.gate(call: 1)
            let launch = Task { await fixture.workflow.appDidBecomeActive() }
            try await fixture.loader.waitForCall(1)
            let refresh = Task { await fixture.workflow.refresh() }
            await Task.yield()
            #expect(await fixture.loader.callCount == 1)
            await fixture.loader.release(call: 1)
            await launch.value
            await refresh.value
            #expect(await fixture.loader.callCount == 1)
        }
    }

    @Test func readingDiscardsOldCountAndCoalescesFollowup() async throws {
        try await withFixture { fixture in
            await fixture.workflow.appDidBecomeActive()
            await fixture.loader.enqueue(.success(.init(privateMessageCount: 20, noticeCount: 3)))
            await fixture.loader.enqueue(.success(.init(privateMessageCount: 0, noticeCount: 0)))
            await fixture.loader.gate(call: 2)
            await fixture.loader.gate(call: 3)
            let oldProbe = Task { await fixture.workflow.refresh(force: true) }
            try await fixture.loader.waitForCall(2)
            let firstRead = fixture.workflow.refreshAfterReading()
            let secondRead = fixture.workflow.refreshAfterReading()
            await fixture.loader.release(call: 2)
            try await fixture.loader.waitForCall(3)
            #expect(fixture.workflow.totalCount == 5)
            await fixture.loader.release(call: 3)
            await oldProbe.value
            await firstRead.value
            await secondRead.value
            #expect(fixture.workflow.totalCount == 0)
            #expect(!fixture.workflow.hasUnreadMessages)
            #expect(await fixture.loader.callCount == 3)
        }
    }

    @Test func failuresPreserveLastCountButAuthenticationFailureClearsIt() async throws {
        try await withFixture { fixture in
            await fixture.loader.enqueue(.failure(YamiboError.securityVerificationRequired))
            await fixture.workflow.appDidBecomeActive()
            #expect(fixture.workflow.summary == nil)
            await fixture.workflow.refresh(force: true)
            #expect(fixture.workflow.totalCount == 5)
            for error in [YamiboError.offline, .securityVerificationRequired, .parsingFailed(context: "unread")] {
                await fixture.loader.enqueue(.failure(error))
                await fixture.workflow.refresh(force: true)
                #expect(fixture.workflow.totalCount == 5)
            }
            await fixture.loader.enqueue(.failure(YamiboError.notAuthenticated))
            await fixture.workflow.refresh(force: true)
            #expect(fixture.workflow.summary == nil)
        }
    }

    @Test func logoutDuringRequestCannotRestoreOldBadge() async throws {
        try await withFixture { fixture in
            await fixture.workflow.appDidBecomeActive()
            await fixture.loader.gate(call: 2)
            let pending = Task { await fixture.workflow.refresh(force: true) }
            try await fixture.loader.waitForCall(2)
            try await fixture.store.reset()
            await fixture.workflow.refresh()
            #expect(fixture.workflow.summary == nil)
            await fixture.loader.release(call: 2)
            await pending.value
            #expect(fixture.workflow.summary == nil)
            #expect(await fixture.loader.callCount == 2)
        }
    }

    @Test func changedAccountDiscardsUncancelableOldResponse() async throws {
        try await withFixture { fixture in
            await fixture.loader.gate(call: 1)
            let old = Task { await fixture.workflow.appDidBecomeActive() }
            try await fixture.loader.waitForCall(1)
            await fixture.loader.enqueue(.success(.init(privateMessageCount: 0, noticeCount: 2)))
            try await fixture.store.save(session(token: "second", uid: "2"))
            await fixture.workflow.refresh()
            #expect(fixture.workflow.totalCount == 2)
            await fixture.loader.release(call: 1)
            await old.value
            #expect(fixture.workflow.totalCount == 2)
        }
    }

    @Test func expiredCookieClearsCountWithoutRequest() async throws {
        try await withFixture { fixture in
            await fixture.workflow.appDidBecomeActive()
            var expired = session()
            expired.cookies = [YamiboCookie(
                name: SessionState.authenticationCookieName,
                value: "first",
                domain: YamiboDomain.forumHost,
                expiresAt: .distantPast
            )]
            try await fixture.store.save(expired)
            await fixture.workflow.refresh(force: true)
            #expect(fixture.workflow.summary == nil)
            #expect(await fixture.loader.callCount == 1)
        }
    }

    @Test func backgroundCancelsProbeAndDoesNotPoll() async throws {
        try await withFixture { fixture in
            await fixture.loader.gate(call: 1)
            let launch = Task { await fixture.workflow.appDidBecomeActive() }
            try await fixture.loader.waitForCall(1)
            fixture.workflow.appDidEnterBackground()
            await fixture.loader.release(call: 1)
            await launch.value
            #expect(fixture.workflow.summary == nil)
            fixture.clock.advance(120)
            await fixture.workflow.refresh(force: true)
            #expect(await fixture.loader.callCount == 1)
            await fixture.workflow.appDidBecomeActive()
            #expect(fixture.workflow.totalCount == 5)
            #expect(await fixture.loader.callCount == 2)
        }
    }

    @Test func sessionObserverHandlesLoginAndLogoutWithoutForegroundChange() async throws {
        try await withFixture(loggedIn: false) { fixture in
            let observer = Task { await fixture.workflow.observeSessionChanges() }
            defer { observer.cancel() }
            await fixture.workflow.appDidBecomeActive()
            #expect(await fixture.loader.callCount == 0)
            try await fixture.store.save(session())
            try await fixture.loader.waitForCall(1)
            await fixture.workflow.refresh()
            #expect(fixture.workflow.totalCount == 5)
            try await fixture.store.reset()
            try await waitForMainActorCondition { fixture.workflow.summary == nil }
            #expect(fixture.workflow.totalCount == 0)
        }
    }

    @Test func ordinaryCookieAndUIDEnrichmentDoNotInvalidatePendingCount() async throws {
        try await withFixture { fixture in
            var initial = session()
            initial.accountUID = nil
            try await fixture.store.save(initial)
            await fixture.loader.gate(call: 1)
            let launch = Task { await fixture.workflow.appDidBecomeActive() }
            try await fixture.loader.waitForCall(1)
            var updated = session()
            updated.cookies.append(YamiboCookie(name: "sid", value: "fresh", domain: YamiboDomain.forumHost))
            try await fixture.store.save(updated)
            let simultaneous = Task { await fixture.workflow.refresh() }
            await fixture.loader.release(call: 1)
            await simultaneous.value
            await launch.value
            #expect(fixture.workflow.totalCount == 5)
            #expect(await fixture.loader.callCount == 1)
        }
    }

    private func session(token: String = "first", uid: String = "1") -> SessionState {
        SessionState(cookie: "\(SessionState.authenticationCookieName)=\(token)", isLoggedIn: true, accountUID: uid)
    }

    private func withFixture(
        loggedIn: Bool = true,
        body: (UnreadWorkflowFixture) async throws -> Void
    ) async throws {
        let name = "MessageUnreadWorkflowTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SessionStore(defaults: defaults)
        if loggedIn { try await store.save(session()) }
        let loader = UnreadWorkflowLoader()
        let clock = UnreadTestClock()
        let workflow = MessageUnreadWorkflow(sessionStore: store, makeRepository: { _ in loader }, now: { clock.now() })
        defer { workflow.appDidEnterBackground() }
        try await body(UnreadWorkflowFixture(store: store, loader: loader, clock: clock, workflow: workflow))
    }
}

private struct UnreadWorkflowFixture {
    let store: SessionStore
    let loader: UnreadWorkflowLoader
    let clock: UnreadTestClock
    let workflow: MessageUnreadWorkflow
}

private actor UnreadWorkflowLoader: MessageUnreadLoading {
    private(set) var callCount = 0
    private var results: [Result<MessageUnreadSummary, any Error>] = []
    private var gates: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func fetchUnreadSummary() async throws -> MessageUnreadSummary {
        callCount += 1
        let call = callCount
        let result = results.isEmpty ? .success(MessageUnreadSummary(privateMessageCount: 2, noticeCount: 3)) : results.removeFirst()
        if gates.contains(call) {
            await withCheckedContinuation { continuations[call] = $0 }
        }
        return try result.get()
    }

    func enqueue(_ result: Result<MessageUnreadSummary, any Error>) { results.append(result) }
    func gate(call: Int) { gates.insert(call) }
    func release(call: Int) { continuations.removeValue(forKey: call)?.resume() }
    func waitForCall(_ count: Int) async throws {
        try await waitForCondition { self.callCount >= count }
    }
}

private final class UnreadTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

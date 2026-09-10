import Testing
import WebKit
@testable import YamiboXCore
@testable import YamiboXUI

@Suite("Isolated account login", .serialized)
@MainActor
struct AccountLoginViewModelTests {
    // The iOS 27 beta's unhosted WebKit runner aborts in NetworkProcessProxy
    // destruction. Keep data stores alive, while still testing coordinator teardown.
    private static var retainedWebsiteStores: [WKWebsiteDataStore] = []

    private func retainWebsiteStore(_ model: AccountLoginViewModel) {
        Self.retainedWebsiteStores.append(model.webCoordinator.webView.configuration.websiteDataStore)
    }

    @Test func canceledCandidateDoesNotReplaceCurrentAccountAndReleasesLease() async throws {
        let store = AccountStore.temporary()
        let sessions = SessionStore(accountStore: store)
        let profiles = YamiboProfileStore(accountStore: store)
        let original = SessionState(cookie: "EeqY_2132_auth=original", isLoggedIn: true, accountUID: "1")
        try await sessions.save(original)
        let model = AccountLoginViewModel(switcher: makeSwitcher(sessions, profiles))
        retainWebsiteStore(model)
        await model.prepare()
        #expect(model.isReady)
        #expect(!model.webCoordinator.webView.configuration.websiteDataStore.isPersistent)
        #expect(await model.sessionStore.load() == SessionState())
        try await model.sessionStore.updateWebSession(cookie: "EeqY_2132_auth=candidate", userAgent: "Candidate", isLoggedIn: true)
        #expect(await sessions.load() == original)
        await #expect(throws: AccountSwitchError.busy) { try await sessions.accountOperations.acquire() }
        model.close()
        for _ in 0..<100 {
            if let token = try? await sessions.accountOperations.acquire() {
                await sessions.accountOperations.release(token)
                #expect(await sessions.load() == original)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Canceled login did not release the account operation lease")
    }

    @Test func separateLoginAttemptsNeverShareWebsiteStores() async throws {
        let store = AccountStore.temporary()
        let switcher = makeSwitcher(SessionStore(accountStore: store), YamiboProfileStore(accountStore: store))
        let first = AccountLoginViewModel(switcher: switcher)
        let second = AccountLoginViewModel(switcher: switcher)
        retainWebsiteStore(first)
        retainWebsiteStore(second)
        #expect(first.webCoordinator.webView.configuration.websiteDataStore !== second.webCoordinator.webView.configuration.websiteDataStore)
        try await first.sessionStore.updateWebSession(cookie: "EeqY_2132_auth=first", userAgent: "first", isLoggedIn: true)
        #expect(!(await second.sessionStore.load().hasValidAuthenticationCookie))
        #expect(!(await second.finishWebLogin()))
        first.close()
        second.close()
    }

    @Test func failedWebVerificationRollsBackOnlyCandidate() async throws {
        let sessions = SessionStore(accountStore: .temporary())
        let original = SessionState(cookie: "EeqY_2132_auth=original", isLoggedIn: true, accountUID: "1")
        try await sessions.save(original)
        let model = AccountLoginViewModel(
            switcher: makeSwitcher(sessions, YamiboProfileStore(accountStore: try #require(sessions.accountStore))),
            verifyWebProfile: { throw URLError(.notConnectedToInternet) }
        )
        retainWebsiteStore(model)
        await model.prepare()
        try await model.sessionStore.updateWebSession(cookie: "EeqY_2132_auth=candidate", userAgent: "candidate", isLoggedIn: true)
        #expect(!(await model.finishWebLogin()))
        #expect(model.errorMessage != nil)
        #expect(!(await model.sessionStore.load().hasValidAuthenticationCookie))
        #expect(await sessions.load() == original)
        model.close()
    }

    @Test func accountChangeClearsOldWebCookiesBeforeInstallingNewIdentity() async throws {
        let sessions = SessionStore(accountStore: .temporary())
        let coordinator = ForumWebSessionCoordinator(sessionStore: sessions, websiteDataStore: .nonPersistent())
        Self.retainedWebsiteStores.append(coordinator.webView.configuration.websiteDataStore)
        let cookieStore = coordinator.webView.configuration.websiteDataStore.httpCookieStore
        let oldCookie = try #require(HTTPCookie(properties: [.domain: "bbs.yamibo.com", .path: "/", .name: "old", .value: "old"]))
        await cookieStore.setCookie(oldCookie)
        let next = SessionState(cookie: "EeqY_2132_auth=new", isLoggedIn: true, accountUID: "2")
        await coordinator.prepareForAccountChange()
        await coordinator.finishAccountChange(next)
        let cookies = await cookieStore.allCookies()
        #expect(!cookies.contains { $0.name == "old" })
        #expect(cookies.contains { $0.name == SessionState.authenticationCookieName && $0.value == "new" })
        await coordinator.tearDown()
    }

    private func makeSwitcher(_ sessions: SessionStore, _ profiles: YamiboProfileStore) -> AccountSwitchCoordinator {
        AccountSwitchCoordinator(sessionStore: sessions, profileStore: profiles,
            makeService: { YamiboAccountService(sessionStore: sessions, profileStore: profiles) },
            transition: { commit in
                let token = try await sessions.beginIdentityTransition()
                do { try await commit(token) }
                catch { await sessions.endIdentityTransition(token); throw error }
                await sessions.endIdentityTransition(token)
            })
    }
}

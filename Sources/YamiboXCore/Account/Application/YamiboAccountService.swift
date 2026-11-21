import Foundation

public struct YamiboAccountService: Sendable {
    private let cookieJar: ForumSessionCookieJar
    private let remote: any YamiboAccountRemoteOperating
    private let sessionStore: SessionStore
    private let profileStore: YamiboProfileStore
    private let userAgent: String
    private let executor: ForumRequestExecutor
    private let websiteDataClearer: (any WebsiteDataClearing)?
    private let coordinatedSignOut: (@Sendable () async throws -> Void)?
    private let coordinatedInvalidation: (@Sendable (UUID?) async throws -> Void)?

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        userAgent: String = YamiboNetworkConfiguration.defaultMobileUserAgent,
        websiteDataClearer: (any WebsiteDataClearing)? = nil,
        executor: ForumRequestExecutor,
        cookieStorageContext: YamiboNetworkPolicy.CookieStorageContext = .standard,
        coordinatedSignOut: (@Sendable () async throws -> Void)? = nil,
        coordinatedInvalidation: (@Sendable (UUID?) async throws -> Void)? = nil,
        remote: (any YamiboAccountRemoteOperating)? = nil
    ) {
        cookieJar = ForumSessionCookieJar(session: session, sessionStore: sessionStore)
        self.remote = remote ?? YamiboAccountRemoteRepository(
            session: session, userAgent: userAgent, executor: executor, sessionStore: sessionStore,
            cookieStorageContext: cookieStorageContext
        )
        self.sessionStore = sessionStore
        self.executor = executor
        self.profileStore = profileStore
        self.userAgent = userAgent
        self.websiteDataClearer = websiteDataClearer
        self.coordinatedSignOut = coordinatedSignOut
        self.coordinatedInvalidation = coordinatedInvalidation
    }

    public static func isolatedLoginService(
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        executor: ForumRequestExecutor
    ) -> YamiboAccountService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = YamiboNetworkConfiguration.requestTimeout
        configuration.timeoutIntervalForResource = YamiboNetworkConfiguration.resourceTimeout
        return YamiboAccountService(
            session: YamiboNetworkConfiguration.makeSession(configuration: configuration),
            sessionStore: sessionStore, profileStore: profileStore, executor: executor,
            cookieStorageContext: .isolatedLogin
        )
    }

    public func login(_ request: YamiboLoginRequest) async throws -> YamiboProfile {
        let baseline = try await sessionStore.snapshot()
        let trimmedUsername = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !request.password.isEmpty else {
            throw YamiboError.loginFailed(L10n.string("error.login_failed"))
        }

        let form = try await remote.fetchLoginForm()
        let loginCookies = await cookieJar.cookies()
        let response = try await remote.submitLogin(
            YamiboLoginRequest(
                username: trimmedUsername,
                password: request.password,
                questionID: request.questionID,
                answer: request.answer
            ),
            form: form,
            credentials: YamiboRequestCredentials(cookies: loginCookies, userAgent: userAgent)
        )

        if response.requiresAdditionalVerification {
            throw YamiboError.loginVerificationRequired
        }

        let cookies = await cookieJar.cookies()
        guard cookies.contains(where: { SessionState.isAuthenticationCookieName($0.name) && !$0.isExpired() }) else {
            throw YamiboError.loginFailed(response.failureMessage)
        }

        let credentials = YamiboRequestCredentials(cookies: cookies, userAgent: userAgent)
        let profile = try await fetchProfile(credentials: credentials)
        guard !profile.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw YamiboError.accountUIDUnavailable }
        let authenticatedCookies = await cookieJar.cookies()
        try Task.checkCancellation()
        guard await sessionStore.isCurrentGeneration(baseline.generation) else { throw CancellationError() }
        try await sessionStore.save(
            SessionState(
                cookies: authenticatedCookies,
                userAgent: userAgent,
                isLoggedIn: true,
                lastUpdatedAt: .now,
                accountUID: profile.uid.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ),
            expectedGeneration: baseline.generation
        )
        try await profileStore.save(profile)
        return profile
    }

    public func refreshProfile() async throws -> YamiboProfile {
        let snapshot = try await sessionStore.snapshot()
        let sessionState = snapshot.session
        guard sessionState.isLoggedIn,
              sessionState.hasValidAuthenticationCookie else {
            if sessionState.isLoggedIn { try await clearLocalAuthentication(expectedGeneration: snapshot.generation) }
            throw YamiboError.notAuthenticated
        }

        let profile: YamiboProfile
        do {
            profile = try await fetchProfile(credentials: sessionState.credentials, handlesCookies: false) {
                guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
            }
        } catch {
            guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
            if LoadDiagnosticError.classificationError(error) as? YamiboError == .notAuthenticated {
                try await clearLocalAuthentication(expectedGeneration: snapshot.generation)
            }
            throw error
        }
        guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
        if let uid = sessionState.accountUID, !uid.isEmpty, profile.uid != uid { throw AccountSwitchError.identityMismatch }
        try await profileStore.save(profile, expectedGeneration: snapshot.generation)
        if !profile.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           profile.uid != sessionState.accountUID {
            try await sessionStore.updateAccountUID(profile.uid, expectedGeneration: snapshot.generation)
        }
        return profile
    }

    public func signOut() async throws {
        if let coordinatedSignOut { try await coordinatedSignOut(); return }
        let sessionState = await sessionStore.load()
        let profile = await profileStore.load()
        await requestServerSignOut(session: sessionState, profile: profile)
        try await clearLocalAuthentication()
    }

    func requestServerSignOut(session sessionState: SessionState, profile: YamiboProfile?) async {
        if let formHash = profile?.formHash?.trimmingCharacters(in: .whitespacesAndNewlines),
           !formHash.isEmpty,
           !sessionState.cookies.isEmpty {
            do {
                try await remote.signOut(credentials: sessionState.credentials, formHash: formHash)
            } catch {
                YamiboLog.account.warning("Best-effort server-side logout request failed, proceeding with local sign-out: \(error)")
            }
        }
    }

    public func clearLocalAuthentication() async throws {
        try await clearLocalAuthentication(expectedGeneration: nil)
    }

    private func clearLocalAuthentication(expectedGeneration: UUID?) async throws {
        if let coordinatedInvalidation { try await coordinatedInvalidation(expectedGeneration); return }
        if let expectedGeneration, !(await sessionStore.isCurrentGeneration(expectedGeneration)) { throw CancellationError() }
        try await sessionStore.reset()
        await profileStore.clear()
        cookieJar.clear()
        await websiteDataClearer?.clearYamiboCookies()
    }

    public func verifySession(_ state: SessionState) async throws -> AuthenticatedAccount {
        guard state.isLoggedIn, state.hasValidAuthenticationCookie else { throw YamiboError.notAuthenticated }
        let candidate = SessionStore(accountStore: .temporary())
        try await candidate.save(state)
        let snapshot = try await candidate.snapshot()
        let profile = try await remote.fetchProfile(
            credentials: state.credentials, handlesCookies: false,
            context: candidate.forumRequestContext(snapshot: snapshot), validateSession: nil
        )
        return AuthenticatedAccount(session: await candidate.load(), profile: profile)
    }

    private func fetchProfile(
        credentials: YamiboRequestCredentials,
        handlesCookies: Bool = true,
        validateSession: (@Sendable () async throws -> Void)? = nil
    ) async throws -> YamiboProfile {
        let snapshot = try await sessionStore.snapshot()
        return try await remote.fetchProfile(
            credentials: credentials, handlesCookies: handlesCookies,
            context: sessionStore.forumRequestContext(snapshot: snapshot, credentials: credentials), validateSession: validateSession
        )
    }

}

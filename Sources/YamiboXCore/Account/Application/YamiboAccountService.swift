import Foundation

public struct YamiboAccountService: Sendable {
    private let session: URLSession
    private let sessionStore: SessionStore
    private let profileStore: YamiboProfileStore
    private let userAgent: String
    private let websiteDataClearer: (any WebsiteDataClearing)?
    private let wafRecoverer: (any YamiboWAFChallengeRecovering)?
    private let coordinatedSignOut: (@Sendable () async throws -> Void)?
    private let coordinatedInvalidation: (@Sendable (UUID?) async throws -> Void)?

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        userAgent: String = YamiboNetworkConfiguration.defaultMobileUserAgent,
        websiteDataClearer: (any WebsiteDataClearing)? = nil,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil,
        coordinatedSignOut: (@Sendable () async throws -> Void)? = nil,
        coordinatedInvalidation: (@Sendable (UUID?) async throws -> Void)? = nil
    ) {
        self.session = session
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.userAgent = userAgent
        self.websiteDataClearer = websiteDataClearer
        self.wafRecoverer = wafRecoverer
        self.coordinatedSignOut = coordinatedSignOut
        self.coordinatedInvalidation = coordinatedInvalidation
    }

    public static func isolatedLoginService(
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil
    ) -> YamiboAccountService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = YamiboNetworkConfiguration.requestTimeout
        configuration.timeoutIntervalForResource = YamiboNetworkConfiguration.resourceTimeout
        return YamiboAccountService(
            session: URLSession(configuration: configuration),
            sessionStore: sessionStore, profileStore: profileStore, wafRecoverer: wafRecoverer
        )
    }

    public func login(_ request: YamiboLoginRequest) async throws -> YamiboProfile {
        let baseline = try await sessionStore.snapshot()
        let trimmedUsername = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !request.password.isEmpty else {
            throw YamiboError.loginFailed(L10n.string("error.login_failed"))
        }

        let form = try await fetchLoginForm()
        let clearance = await sessionStore.load().cookies.filter { YamiboCookie.isWAFCookie($0.name) }
        let client = YamiboClient(
            session: session, credentials: YamiboRequestCredentials(cookies: clearance, userAgent: userAgent), wafRecoverer: wafRecoverer
        )
        let responseHTML = try await client.submitForm(
            url: form.actionURL,
            fields: loginFields(
                form: form,
                username: trimmedUsername,
                password: request.password,
                questionID: request.questionID,
                answer: request.answer
            )
        )

        if requiresAdditionalVerification(responseHTML) {
            throw YamiboError.loginVerificationRequired
        }

        let cookies = await currentCookies()
        guard cookies.contains(where: { $0.name == SessionState.authenticationCookieName && !$0.isExpired() }) else {
            throw YamiboError.loginFailed(extractLoginFailureMessage(from: responseHTML))
        }

        let credentials = YamiboRequestCredentials(cookies: cookies, userAgent: userAgent)
        let profile = try await fetchProfile(credentials: credentials)
        guard !profile.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw YamiboError.accountUIDUnavailable }
        try Task.checkCancellation()
        guard await sessionStore.isCurrentGeneration(baseline.generation) else { throw CancellationError() }
        try await sessionStore.save(
            SessionState(
                cookies: cookies,
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
            let client = YamiboClient(
                session: session,
                credentials: sessionState.credentials,
                handlesCookies: false
            )
            do {
                _ = try await client.fetchHTML(for: .logout(formHash: formHash))
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
        clearHTTPCookies()
        await websiteDataClearer?.clearYamiboCookies()
    }

    public func verifySession(_ state: SessionState) async throws -> YamiboProfile {
        guard state.isLoggedIn, state.hasValidAuthenticationCookie else { throw YamiboError.notAuthenticated }
        // Verification must never borrow the active account's WAF recovery session.
        let client = YamiboClient(session: session, credentials: state.credentials, handlesCookies: false)
        let html = try await client.fetchHTML(for: .currentProfile, cachePolicy: .reloadIgnoringLocalCacheData)
        return try LoadDiagnosticError.parsing(html: html, context: "YamiboProfileParser.parse") {
            try YamiboProfileParser.parse(html)
        }
    }

    private func fetchLoginForm() async throws -> YamiboLoginForm {
        let client = YamiboClient(session: session, userAgent: userAgent, wafRecoverer: wafRecoverer)
        let html = try await client.fetchHTML(for: .login, cachePolicy: .reloadIgnoringLocalCacheData)
        return try LoadDiagnosticError.parsing(html: html, context: "YamiboLoginFormParser.parse") {
            try YamiboLoginFormParser.parse(html)
        }
    }

    private func fetchProfile(
        credentials: YamiboRequestCredentials,
        handlesCookies: Bool = true,
        validateSession: (@Sendable () async throws -> Void)? = nil
    ) async throws -> YamiboProfile {
        let client = YamiboClient(session: session, credentials: credentials, wafRecoverer: wafRecoverer,
                                  handlesCookies: handlesCookies, validateSession: validateSession)
        let html = try await client.fetchHTML(for: .currentProfile, cachePolicy: .reloadIgnoringLocalCacheData)
        return try LoadDiagnosticError.parsing(html: html, context: "YamiboProfileParser.parse") {
            try YamiboProfileParser.parse(html)
        }
    }

    private func loginFields(
        form: YamiboLoginForm,
        username: String,
        password: String,
        questionID: String,
        answer: String
    ) -> [(String, String)] {
        var fields = form.hiddenFields.filter { name, _ in
            !["username", "password", "questionid", "answer", "submit"].contains(name)
        }
        fields.append(("username", username))
        fields.append(("password", password))
        fields.append(("questionid", questionID))
        fields.append(("answer", answer))
        fields.append(("submit", "true"))
        return fields
    }

    private func currentCookies() async -> [YamiboCookie] {
        let storageCookies = cookieStorages()
            .flatMap { $0.cookies ?? [] }
            .filter { YamiboDomain.isYamiboCookieDomain($0.domain) }

        var uniqueCookies: [String: YamiboCookie] = [:]
        for cookie in storageCookies {
            let stored = YamiboCookie(cookie)
            uniqueCookies[stored.identity] = stored
        }
        for cookie in await sessionStore.load().cookies where YamiboCookie.isWAFCookie(cookie.name) {
            uniqueCookies[cookie.identity] = cookie
        }

        return uniqueCookies.values
            .sorted { $0.identity < $1.identity }
    }

    private func cookieStorages() -> [HTTPCookieStorage] {
        var storages: [HTTPCookieStorage] = []
        if let storage = session.configuration.httpCookieStorage {
            storages.append(storage)
        }
        return storages
    }

    private func clearHTTPCookies() {
        for storage in cookieStorages() {
            for cookie in storage.cookies ?? [] where YamiboDomain.containsYamiboDomain(cookie.domain) {
                storage.deleteCookie(cookie)
            }
        }
    }


    private func requiresAdditionalVerification(_ html: String) -> Bool {
        let markers = [
            "seccode",
            "captcha",
            "验证码",
            "驗證碼",
            "cf-challenge",
            "cloudflare"
        ]
        return markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

    private func extractLoginFailureMessage(from html: String) -> String {
        guard let document = try? KannaSoup.parse(html) else {
            return L10n.string("error.login_failed")
        }

        let selectors = [
            ".jump_c p",
            ".jump_c",
            "#messagetext",
            ".alert_info",
            ".msgbox"
        ]

        for selector in selectors {
            guard let text = document.select(selector).first()?.text() else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return L10n.string("error.login_failed")
    }
}

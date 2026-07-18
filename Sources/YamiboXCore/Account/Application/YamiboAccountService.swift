import Foundation

public struct YamiboAccountService: Sendable {
    private let session: URLSession
    private let sessionStore: SessionStore
    private let profileStore: YamiboProfileStore
    private let userAgent: String
    private let websiteDataClearer: (any WebsiteDataClearing)?

    init(
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        sessionStore: SessionStore,
        profileStore: YamiboProfileStore,
        userAgent: String = YamiboNetworkConfiguration.defaultMobileUserAgent,
        websiteDataClearer: (any WebsiteDataClearing)? = nil
    ) {
        self.session = session
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.userAgent = userAgent
        self.websiteDataClearer = websiteDataClearer
    }

    public func login(_ request: YamiboLoginRequest) async throws -> YamiboProfile {
        let trimmedUsername = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !request.password.isEmpty else {
            throw YamiboError.loginFailed(L10n.string("error.login_failed"))
        }

        let form = try await fetchLoginForm()
        let client = YamiboClient(session: session, userAgent: userAgent)
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

        let cookieHeader = currentCookieHeader()
        guard SessionState.hasAuthenticationCookie(cookieHeader) else {
            throw YamiboError.loginFailed(extractLoginFailureMessage(from: responseHTML))
        }

        let profile = try await fetchProfile(cookie: cookieHeader, userAgent: userAgent)
        try await sessionStore.save(
            SessionState(
                cookie: cookieHeader,
                userAgent: userAgent,
                isLoggedIn: true,
                lastUpdatedAt: .now,
                accountUID: profile.uid.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        )
        try await profileStore.save(profile)
        return profile
    }

    public func refreshProfile() async throws -> YamiboProfile {
        let sessionState = await sessionStore.load()
        guard sessionState.isLoggedIn,
              SessionState.hasAuthenticationCookie(sessionState.cookie) else {
            throw YamiboError.notAuthenticated
        }

        let profile = try await fetchProfile(
            cookie: sessionState.cookie,
            userAgent: sessionState.userAgent
        )
        try await profileStore.save(profile)
        if !profile.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           profile.uid != sessionState.accountUID {
            try await sessionStore.updateAccountUID(profile.uid)
        }
        return profile
    }

    public func signOut() async throws {
        let sessionState = await sessionStore.load()
        let profile = await profileStore.load()
        if let formHash = profile?.formHash?.trimmingCharacters(in: .whitespacesAndNewlines),
           !formHash.isEmpty,
           !sessionState.cookie.isEmpty {
            let client = YamiboClient(
                session: session,
                cookie: sessionState.cookie,
                userAgent: sessionState.userAgent
            )
            do {
                _ = try await client.fetchHTML(for: .logout(formHash: formHash))
            } catch {
                YamiboLog.account.warning("Best-effort server-side logout request failed, proceeding with local sign-out: \(error)")
            }
        }
        try await clearLocalAuthentication()
    }

    public func clearLocalAuthentication() async throws {
        try await sessionStore.reset()
        await profileStore.clear()
        clearHTTPCookies()
        await websiteDataClearer?.clearYamiboCookies()
    }

    private func fetchLoginForm() async throws -> YamiboLoginForm {
        let client = YamiboClient(session: session, userAgent: userAgent)
        let html = try await client.fetchHTML(for: .login, cachePolicy: .reloadIgnoringLocalCacheData)
        return try YamiboLoginFormParser.parse(html)
    }

    private func fetchProfile(cookie: String, userAgent: String) async throws -> YamiboProfile {
        let client = YamiboClient(session: session, cookie: cookie, userAgent: userAgent)
        let html = try await client.fetchHTML(for: .currentProfile, cachePolicy: .reloadIgnoringLocalCacheData)
        return try YamiboProfileParser.parse(html)
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

    private func currentCookieHeader() -> String {
        let storageCookies = cookieStorages()
            .flatMap { $0.cookies ?? [] }
            .filter { YamiboDomain.isYamiboCookieDomain($0.domain) }

        var uniqueCookies: [String: HTTPCookie] = [:]
        for cookie in storageCookies {
            uniqueCookies["\(cookie.domain)|\(cookie.path)|\(cookie.name)"] = cookie
        }

        return uniqueCookies.values
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func cookieStorages() -> [HTTPCookieStorage] {
        var storages: [HTTPCookieStorage] = []
        if let storage = session.configuration.httpCookieStorage {
            storages.append(storage)
        }
        if !storages.contains(where: { $0 === HTTPCookieStorage.shared }) {
            storages.append(.shared)
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


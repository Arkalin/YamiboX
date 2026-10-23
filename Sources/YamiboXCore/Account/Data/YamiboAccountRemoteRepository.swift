import Foundation

struct YamiboAccountRemoteRepository: YamiboAccountRemoteOperating {
    let session: URLSession
    let userAgent: String
    let executor: ForumRequestExecutor
    let sessionStore: SessionStore
    private var cookieStorageID: UUID { sessionStore.forumScopeID }
    let cookieStorageContext: YamiboNetworkPolicy.CookieStorageContext

    func fetchLoginForm() async throws -> YamiboLoginForm {
        let snapshot = try await sessionStore.snapshot()
        let client = YamiboClient(
            session: session, context: sessionStore.forumRequestContext(snapshot: snapshot,
                credentials: YamiboRequestCredentials(cookies: snapshot.session.cookies, userAgent: userAgent), cookieStorageID: cookieStorageID),
            executor: executor, handlesCookies: true,
            cookieStorageContext: cookieStorageContext
        )
        let html = try await client.fetchHTML(for: .login, cachePolicy: .reloadIgnoringLocalCacheData)
        return try LoadDiagnosticError.parsing(html: html, context: "YamiboLoginFormParser.parse") {
            try YamiboLoginFormParser.parse(html)
        }
    }

    func submitLogin(
        _ request: YamiboLoginRequest,
        form: YamiboLoginForm,
        credentials: YamiboRequestCredentials
    ) async throws -> YamiboLoginResponse {
        let snapshot = try await sessionStore.snapshot()
        let client = YamiboClient(
            session: session, context: sessionStore.forumRequestContext(snapshot: snapshot, credentials: credentials, cookieStorageID: cookieStorageID),
            executor: executor, handlesCookies: true, cookieStorageContext: cookieStorageContext
        )
        var fields = form.hiddenFields.filter { name, _ in
            !["username", "password", "questionid", "answer", "submit"].contains(name)
        }
        fields.append(("username", request.username))
        fields.append(("password", request.password))
        fields.append(("questionid", request.questionID))
        fields.append(("answer", request.answer))
        fields.append(("submit", "true"))
        let html = try await client.submitForm(url: form.actionURL, fields: fields)
        return YamiboLoginResponse(
            requiresAdditionalVerification: requiresAdditionalVerification(html),
            failureMessage: extractLoginFailureMessage(from: html)
        )
    }

    func fetchProfile(
        credentials: YamiboRequestCredentials,
        handlesCookies: Bool,
        context: ForumRequestContext,
        validateSession: (@Sendable () async throws -> Void)?
    ) async throws -> YamiboProfile {
        let client = YamiboClient(
            session: session, context: context.replacingCredentials(credentials), executor: executor,
            handlesCookies: handlesCookies, cookieStorageContext: cookieStorageContext,
            validateSession: validateSession
        )
        let html = try await client.fetchHTML(for: .currentProfile, cachePolicy: .reloadIgnoringLocalCacheData)
        return try LoadDiagnosticError.parsing(html: html, context: "YamiboProfileParser.parse") {
            try YamiboProfileParser.parse(html)
        }
    }

    func signOut(credentials: YamiboRequestCredentials, formHash: String) async throws {
        let retired = SessionStore(accountStore: .temporary())
        let snapshot = try await retired.snapshot()
        let client = YamiboClient(session: session,
            context: retired.forumRequestContext(snapshot: snapshot, credentials: credentials), executor: executor)
        _ = try await client.fetchHTML(for: .logout(formHash: formHash))
    }

    private func requiresAdditionalVerification(_ html: String) -> Bool {
        let markers = ["seccode", "captcha", "验证码", "驗證碼", "cf-challenge", "cloudflare"]
        return markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

    private func extractLoginFailureMessage(from html: String) -> String {
        guard let document = try? KannaSoup.parse(html) else {
            return L10n.string("error.login_failed")
        }
        let selectors = [".jump_c p", ".jump_c", "#messagetext", ".alert_info", ".msgbox"]
        for selector in selectors {
            guard let text = document.select(selector).first()?.text() else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return L10n.string("error.login_failed")
    }
}

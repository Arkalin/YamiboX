import Foundation

struct YamiboAccountRemoteRepository: YamiboAccountRemoteOperating {
    let session: URLSession
    let userAgent: String
    let wafRecoverer: (any YamiboWAFChallengeRecovering)?
    let cookieStorageContext: YamiboNetworkPolicy.CookieStorageContext

    func fetchLoginForm() async throws -> YamiboLoginForm {
        let client = YamiboClient(
            session: session, userAgent: userAgent, wafRecoverer: wafRecoverer,
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
        let client = YamiboClient(
            session: session, credentials: credentials,
            wafRecoverer: wafRecoverer, cookieStorageContext: cookieStorageContext
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
        allowsWAFRecovery: Bool,
        validateSession: (@Sendable () async throws -> Void)?
    ) async throws -> YamiboProfile {
        let client = YamiboClient(
            session: session, credentials: credentials,
            wafRecoverer: allowsWAFRecovery ? wafRecoverer : nil,
            handlesCookies: handlesCookies, cookieStorageContext: cookieStorageContext,
            validateSession: validateSession
        )
        let html = try await client.fetchHTML(for: .currentProfile, cachePolicy: .reloadIgnoringLocalCacheData)
        return try LoadDiagnosticError.parsing(html: html, context: "YamiboProfileParser.parse") {
            try YamiboProfileParser.parse(html)
        }
    }

    func signOut(credentials: YamiboRequestCredentials, formHash: String) async throws {
        let client = YamiboClient(session: session, credentials: credentials, handlesCookies: false)
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

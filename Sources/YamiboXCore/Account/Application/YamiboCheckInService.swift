import Foundation

public enum YamiboCheckInResult: Equatable, Sendable {
    case success
    case alreadyCheckedInToday
    case skippedToday
    case notAuthenticated
    case parseFailed
    case verificationFailed
    case networkFailed(String)

    public var message: String {
        switch self {
        case .success:
            L10n.string("yamibo_check_in.success")
        case .alreadyCheckedInToday, .skippedToday:
            L10n.string("yamibo_check_in.already_checked_in_today")
        case .notAuthenticated:
            L10n.string("yamibo_check_in.not_authenticated")
        case .parseFailed:
            L10n.string("yamibo_check_in.parse_failed")
        case .verificationFailed:
            L10n.string("yamibo_check_in.verification_failed")
        case let .networkFailed(message):
            message
        }
    }
}

public protocol YamiboCheckInServicing: Sendable {
    func checkInIfNeeded(force: Bool) async -> YamiboCheckInResult
}

struct YamiboCheckInService: YamiboCheckInServicing, Sendable {
    static let checkInPageURL = YamiboDomain.url(forSitePath: "plugin.php?id=zqlj_sign&mobile=2")!
    static let enhancedCheckInPromotionBaseURL = YamiboDomain.baseURL

    private let sessionStore: SessionStore
    private let checkInStore: YamiboCheckInStore
    private let settingsStore: SettingsStore
    private let session: URLSession
    private let promotionSession: URLSession
    private let verificationDelayNanoseconds: UInt64
    private let wafRecoverer: (any YamiboWAFChallengeRecovering)?

    init(
        sessionStore: SessionStore,
        checkInStore: YamiboCheckInStore,
        settingsStore: SettingsStore = SettingsStore(),
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        promotionSession: URLSession = YamiboNetworkConfiguration.makeCookieIsolatedSession(),
        verificationDelayNanoseconds: UInt64 = 3_000_000_000,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil
    ) {
        self.sessionStore = sessionStore
        self.checkInStore = checkInStore
        self.settingsStore = settingsStore
        self.session = session
        self.promotionSession = promotionSession
        self.verificationDelayNanoseconds = verificationDelayNanoseconds
        self.wafRecoverer = wafRecoverer
    }

    func checkInIfNeeded(force: Bool = false) async -> YamiboCheckInResult {
        let sessionState = await sessionStore.load()
        guard sessionState.isLoggedIn, !sessionState.cookie.isEmpty else {
            return .notAuthenticated
        }

        if !force {
            let needsCheckIn = await checkInStore.needsCheckIn(session: sessionState)
            if !needsCheckIn {
                return .skippedToday
            }
        }

        await startEnhancedCheckInPromotionVisit(for: sessionState)

        let client = YamiboClient(
            session: session,
            credentials: sessionState.credentials,
            wafRecoverer: wafRecoverer
        )

        let checkInPageHTML: String
        do {
            checkInPageHTML = try await client.fetchHTML(url: Self.checkInPageURL)
        } catch {
            return mapNetworkError(error)
        }

        if Self.isAlreadyCheckedIn(in: checkInPageHTML) {
            await checkInStore.markCheckedIn(session: sessionState)
            return .alreadyCheckedInToday
        }

        guard let checkInURL = Self.extractCheckInURL(from: checkInPageHTML) else {
            return .parseFailed
        }

        do {
            _ = try await client.fetchHTML(url: checkInURL)
        } catch {
            return mapNetworkError(error)
        }

        if verificationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: verificationDelayNanoseconds)
        }

        do {
            let verificationHTML = try await client.fetchHTML(url: Self.checkInPageURL)
            guard Self.isAlreadyCheckedIn(in: verificationHTML) else {
                return .verificationFailed
            }
            await checkInStore.markCheckedIn(session: sessionState)
            return .success
        } catch {
            return mapNetworkError(error)
        }
    }

    /// Starts the referral visit separately from the user-visible check-in
    /// flow. Its credentials are limited to valid WAF clearance cookies from
    /// the initial request through any WAF recovery retry.
    private func startEnhancedCheckInPromotionVisit(for sessionState: SessionState) async {
        let settings = await settingsStore.load()
        guard settings.system.enhancedCheckInEnabled,
              let url = Self.enhancedCheckInPromotionURL(for: sessionState.accountUID),
              let credentials = Self.wafOnlyCredentials(from: sessionState, for: url)
        else {
            return
        }

        let client = YamiboClient(
            session: promotionSession,
            credentials: credentials,
            wafRecoverer: wafRecoverer.map { WAFOnlyChallengeRecoverer(base: $0) },
            handlesCookies: false
        )

        Task {
            _ = try? await client.fetchHTML(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                cancellationPolicy: .completeStartedRequest
            )
        }
    }

    private static func enhancedCheckInPromotionURL(for rawUID: String?) -> URL? {
        guard let uid = normalizedNumericUID(rawUID) else { return nil }
        var components = URLComponents(url: enhancedCheckInPromotionBaseURL, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.queryItems = [URLQueryItem(name: "fromuid", value: uid)]
        return components?.url
    }

    private static func normalizedNumericUID(_ rawUID: String?) -> String? {
        guard let uid = rawUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty,
              uid.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 })
        else {
            return nil
        }
        return uid
    }

    private static func wafOnlyCredentials(
        from sessionState: SessionState,
        for url: URL
    ) -> YamiboRequestCredentials? {
        let credentials = YamiboRequestCredentials(
            cookies: sessionState.cookies.filter { YamiboCookie.isWAFCookie($0.name) },
            userAgent: sessionState.userAgent
        )
        return credentials.cookieHeader(for: url).isEmpty ? nil : credentials
    }

    private func mapNetworkError(_ error: Error) -> YamiboCheckInResult {
        if let yamiboError = error as? YamiboError, yamiboError == .notAuthenticated {
            return .notAuthenticated
        }
        let message = (error as? LocalizedError)?.errorDescription ?? L10n.string("yamibo_check_in.network_failed")
        return .networkFailed(message.isEmpty ? L10n.string("yamibo_check_in.network_failed") : message)
    }

    private static func isAlreadyCheckedIn(in html: String) -> Bool {
        // Structural checks first (sign-plugin calendar marks today `.on`, the
        // sign button loses its `sign=` href); the literal marker is a fallback
        // in case the plugin's markup drifts.
        if let document = try? KannaSoup.parse(html) {
            if let today = document.selectFirst("#tablebody .day.today"), today.hasClass("on") {
                return true
            }
            if let button = document.selectFirst(".signbtn a.btna"),
               button.normalizedText().contains("已打卡") {
                return true
            }
        }
        return html.contains(#"class="btna">今日已打卡</a>"#)
    }

    private static func extractCheckInURL(from html: String) -> URL? {
        if let document = try? KannaSoup.parse(html),
           let href = document.selectFirst(".signbtn a.btna[href*='sign=']")?.attrText("href"),
           let url = HTMLTextExtractor.absoluteURL(from: href) {
            return url
        }
        guard html.contains(#"class="btna">点击打卡</a>"#) else {
            return nil
        }

        let pattern = #"href="(plugin\.php\?id=zqlj_sign(?:&amp;|&)sign=[^"]+)""#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
            let range = Range(match.range(at: 1), in: html)
        else {
            return nil
        }

        let path = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: path, relativeTo: YamiboDomain.baseURL)?.absoluteURL
    }
}

private struct WAFOnlyChallengeRecoverer: YamiboWAFChallengeRecovering {
    private let base: any YamiboWAFChallengeRecovering

    init(base: any YamiboWAFChallengeRecovering) {
        self.base = base
    }

    func recover(from challenge: YamiboWAFChallenge) async throws -> YamiboRequestCredentials {
        let recovered = try await base.recover(from: challenge)
        let wafOnly = YamiboRequestCredentials(
            cookies: recovered.cookies.filter { YamiboCookie.isWAFCookie($0.name) },
            userAgent: recovered.userAgent
        )
        guard !wafOnly.cookieHeader(for: challenge.url).isEmpty else {
            throw YamiboError.securityVerificationRequired
        }
        return wafOnly
    }

    /// A failed background referral must not show an additional fallback UI.
    func presentFallback(for _: YamiboWAFChallenge) async {}
}

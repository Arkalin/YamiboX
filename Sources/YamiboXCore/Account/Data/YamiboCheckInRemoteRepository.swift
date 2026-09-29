import Foundation

struct YamiboCheckInRemoteRepository: YamiboCheckInRemoteOperating {
    private static let checkInPageURL = YamiboDomain.url(forSitePath: "plugin.php?id=zqlj_sign&mobile=2")!
    private static let enhancedCheckInPromotionBaseURL = YamiboDomain.baseURL

    private let client: YamiboClient
    private let sessionState: SessionState
    private let promotionSession: URLSession
    private let wafRecoverer: (any YamiboWAFChallengeRecovering)?
    private let sessionStore: SessionStore
    private let generation: UUID

    init(
        session: URLSession,
        snapshot: AccountSessionSnapshot,
        sessionStore: SessionStore,
        promotionSession: URLSession,
        wafRecoverer: (any YamiboWAFChallengeRecovering)?
    ) {
        self.client = YamiboClient(
            session: session,
            credentials: snapshot.session.credentials,
            wafRecoverer: wafRecoverer,
            handlesCookies: false,
            validateSession: {
                guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
            }
        )
        self.sessionState = snapshot.session
        self.promotionSession = promotionSession
        self.wafRecoverer = wafRecoverer
        self.sessionStore = sessionStore
        self.generation = snapshot.generation
    }

    private func currentClient() async throws -> YamiboClient {
        let snapshot = try await sessionStore.snapshot()
        guard snapshot.generation == generation,
              await sessionStore.isCurrentGeneration(generation) else { throw CancellationError() }
        var client = client
        client.credentials = YamiboRequestCredentials(
            cookies: sessionState.cookies.filter { !YamiboCookie.isWAFCookie($0.name) }
                + snapshot.session.cookies.filter { YamiboCookie.isWAFCookie($0.name) },
            userAgent: sessionState.userAgent
        )
        return client
    }

    func loadPage() async throws -> YamiboCheckInPage {
        let client = try await currentClient()
        let html = try await client.fetchHTML(url: Self.checkInPageURL)
        if Self.isAlreadyCheckedIn(in: html) { return .alreadyCheckedIn }
        if let url = Self.extractCheckInURL(from: html) { return .available(url) }
        return .unavailable(LoadFailureDetails(
            error: YamiboError.parsingFailed(context: L10n.string("yamibo_check_in.parse_failed")),
            requestContext: Self.checkInPageURL.absoluteString, html: html
        ))
    }

    func submit(at url: URL) async throws {
        let client = try await currentClient()
        _ = try await client.fetchHTML(url: url)
    }

    func verifyCheckIn() async throws -> Bool {
        let client = try await currentClient()
        let html = try await client.fetchHTML(url: Self.checkInPageURL)
        return Self.isAlreadyCheckedIn(in: html)
    }

    /// A separate best-effort visit with WAF-only credentials, including retries.
    func startPromotionVisit() {
        guard let url = Self.enhancedCheckInPromotionURL(for: sessionState.accountUID),
              let credentials = Self.wafOnlyCredentials(from: sessionState, for: url) else {
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

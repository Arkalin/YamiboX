import Foundation

struct YamiboCheckInRemoteRepository: YamiboCheckInRemoteOperating {
    private let client: YamiboClient
    private let promotionClient: YamiboClient
    private let accountUID: String?

    init(
        session: URLSession,
        snapshot: AccountSessionSnapshot,
        sessionStore: SessionStore,
        promotionSession: URLSession,
        requestExecutor: ForumRequestExecutor
    ) {
        self.client = YamiboClient(
            session: session,
            context: sessionStore.forumRequestContext(snapshot: snapshot),
            executor: requestExecutor,
            handlesCookies: false,
            validateSession: {
                guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
            }
        )
        promotionClient = YamiboClient(
            session: promotionSession, context: client.requestContext, executor: requestExecutor, handlesCookies: false
        )
        accountUID = snapshot.session.accountUID
    }

    func loadPage() async throws -> YamiboCheckInPage {
        let html = try await client.fetchHTML(for: .checkInPage, cachePolicy: .reloadIgnoringLocalCacheData)
        if Self.isAlreadyCheckedIn(in: html) { return .alreadyCheckedIn }
        if let url = Self.extractCheckInURL(from: html) { return .available(url) }
        return .unavailable(LoadFailureDetails(
            error: YamiboError.parsingFailed(context: L10n.string("yamibo_check_in.parse_failed")),
            requestContext: YamiboRoute.checkInPage.url.absoluteString, html: html
        ))
    }

    func submit(at url: URL) async throws {
        _ = try await client.fetchHTML(for: .checkInSubmission(url: url))
    }

    func verifyCheckIn() async throws -> Bool {
        let html = try await client.fetchHTML(for: .checkInPage, cachePolicy: .reloadIgnoringLocalCacheData)
        return Self.isAlreadyCheckedIn(in: html)
    }

    func startPromotionVisit() {
        guard let uid = Self.normalizedNumericUID(accountUID) else { return }
        Task {
            _ = try? await promotionClient.fetchHTML(
                for: .checkInPromotion(uid: uid),
                cachePolicy: .reloadIgnoringLocalCacheData,
                cancellationPolicy: .completeStartedRequest
            )
        }
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

    private static func isAlreadyCheckedIn(in html: String) -> Bool {
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

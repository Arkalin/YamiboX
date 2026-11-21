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
        guard let document = try? KannaSoup.parse(html) else { return false }
        if document.selectAll("#tablebody .day.today").contains(where: {
            YamiboHTMLPageInspector.isVisibleNotice($0) && $0.hasClass("on")
        }) {
            return true
        }
        if document.selectAll(".signbtn a.btna").contains(where: {
            YamiboHTMLPageInspector.isVisibleNotice($0)
                && ["今日已打卡", "已打卡", "今日已簽到", "今日已签到"].contains(YamiboHTMLPageInspector.visibleNoticeText($0))
        }) {
            return true
        }
        return document.selectAll("a.btna").contains {
            YamiboHTMLPageInspector.isVisibleNotice($0) && YamiboHTMLPageInspector.visibleNoticeText($0) == "今日已打卡"
        }
    }

    private static func extractCheckInURL(from html: String) -> URL? {
        guard let document = try? KannaSoup.parse(html) else { return nil }
        let buttons = document.selectAll(".signbtn a.btna") + document.selectAll("a.btna")
        for button in buttons where YamiboHTMLPageInspector.isVisibleNotice(button)
            && ["点击打卡", "點擊打卡", "点击签到", "點擊簽到"].contains(YamiboHTMLPageInspector.visibleNoticeText(button)) {
            guard let url = button.attrText("href").flatMap({ HTMLTextExtractor.absoluteURL(from: $0) }),
                  YamiboDomain.isForumURL(url), url.path.hasSuffix("/plugin.php"),
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.contains(where: { $0.name == "id" && $0.value == "zqlj_sign" }),
                  items.contains(where: { $0.name == "sign" && $0.value?.isEmpty == false })
            else { continue }
            return url
        }
        return nil
    }
}

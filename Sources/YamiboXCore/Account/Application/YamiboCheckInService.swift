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

    private let sessionStore: SessionStore
    private let checkInStore: YamiboCheckInStore
    private let session: URLSession
    private let verificationDelayNanoseconds: UInt64

    init(
        sessionStore: SessionStore,
        checkInStore: YamiboCheckInStore,
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        verificationDelayNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.sessionStore = sessionStore
        self.checkInStore = checkInStore
        self.session = session
        self.verificationDelayNanoseconds = verificationDelayNanoseconds
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

        let client = YamiboClient(
            session: session,
            cookie: sessionState.cookie,
            userAgent: sessionState.userAgent
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

    private func mapNetworkError(_ error: Error) -> YamiboCheckInResult {
        if let yamiboError = error as? YamiboError, yamiboError == .notAuthenticated {
            return .notAuthenticated
        }
        let message = (error as? LocalizedError)?.errorDescription ?? L10n.string("yamibo_check_in.network_failed")
        return .networkFailed(message.isEmpty ? L10n.string("yamibo_check_in.network_failed") : message)
    }

    private static func isAlreadyCheckedIn(in html: String) -> Bool {
        html.contains(#"class="btna">今日已打卡</a>"#)
    }

    private static func extractCheckInURL(from html: String) -> URL? {
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

import Foundation

public enum ForumWAFFailure: String, Error, Sendable, LocalizedError {
    case challenge
    case silentTimeout
    case runtimeUnavailable
    case interactionRequired
    case sessionInvalidated
    case noUpdatedClearance
    case processTerminated
    case replayNotPermitted
    case replayExhausted

    /// Suitable for inline load/queue failure, not an instruction to open login.
    public var errorDescription: String? {
        switch self {
        case .challenge: "请求遇到站点安全验证。"
        case .silentTimeout: "站点静默验证超时，请稍后重试。"
        case .runtimeUnavailable: "当前无法运行站点静默验证，请稍后重试。"
        case .interactionRequired: "站点验证需要人工操作，已停止本次请求。"
        case .sessionInvalidated: "请求所属会话已失效。"
        case .noUpdatedClearance: "站点验证未取得新的有效通行状态。"
        case .processTerminated: "站点静默验证进程已结束。"
        case .replayNotPermitted: "通行状态已更新；为避免重复操作，本次请求未自动重发。"
        case .replayExhausted: "自动重试后仍被站点阻止，请稍后重试。"
        }
    }
}

/// A verifier cannot return account credentials or change the request's UA.
public struct ForumWAFResult: Sendable {
    public let cookies: [YamiboCookie]

    public init(cookies: [YamiboCookie]) {
        self.cookies = YamiboCookie.canonicalCookies(cookies.filter { YamiboCookie.isWAFCookie($0.name) })
    }

    public func hasUpdatedClearance(for challenge: YamiboWAFChallenge, at date: Date = .now) -> Bool {
        cookies.contains {
            $0.name == "nox_jst_v1" && $0.matches(challenge.url, at: date)
                && ($0.expiresAt?.timeIntervalSince(date) ?? 0) > 60
                && (YamiboWAFChallenge.clearanceFingerprint(for: $0.value) != challenge.clearanceFingerprint
                    || $0.expiresAt != challenge.clearanceExpiresAt)
        }
    }
}

public struct ForumSilentVerificationRequest: Sendable {
    public let flightID: UUID
    public let key: ForumSessionKey
    public let challenge: YamiboWAFChallenge
    public let baseline: ForumWAFResult
    public let deadline: ContinuousClock.Instant

    public init(flightID: UUID, key: ForumSessionKey, challenge: YamiboWAFChallenge,
                baseline: ForumWAFResult, deadline: ContinuousClock.Instant) {
        self.flightID = flightID
        self.key = key
        self.challenge = challenge
        self.baseline = baseline
        self.deadline = deadline
    }
}

/// No presentation, navigation, login or fallback authority. Cancellation must
/// tear down the platform resources, not leave a suspended browser behind.
public protocol ForumSilentVerifying: Sendable {
    func verify(_ request: ForumSilentVerificationRequest) async throws -> ForumWAFResult
}

public struct UnavailableForumSilentVerifier: ForumSilentVerifying {
    public init() {}

    public func verify(_ request: ForumSilentVerificationRequest) async throws -> ForumWAFResult {
        try Task.checkCancellation()
        throw ForumWAFFailure.runtimeUnavailable
    }
}

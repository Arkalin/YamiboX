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
    func checkInWithDetails(force: Bool) async -> YamiboCheckInOutcome
}

public struct YamiboCheckInOutcome: Sendable {
    public let result: YamiboCheckInResult
    public let details: LoadFailureDetails?
    public let isCancelled: Bool
    public let requiresSecurityVerification: Bool

    public init(result: YamiboCheckInResult, details: LoadFailureDetails? = nil, isCancelled: Bool = false, requiresSecurityVerification: Bool = false) {
        self.result = result
        self.details = details
        self.isCancelled = isCancelled
        self.requiresSecurityVerification = requiresSecurityVerification
    }
}

public extension YamiboCheckInServicing {
    func checkInWithDetails(force: Bool) async -> YamiboCheckInOutcome {
        let result = await checkInIfNeeded(force: force)
        return YamiboCheckInOutcome(result: result, isCancelled: Task.isCancelled)
    }
}

struct YamiboCheckInService: YamiboCheckInServicing, Sendable {
    private let sessionStore: SessionStore
    private let checkInStore: YamiboCheckInStore
    private let settingsStore: SettingsStore
    private let verificationDelayNanoseconds: UInt64
    private let makeRemote: @Sendable (AccountSessionSnapshot) -> any YamiboCheckInRemoteOperating

    init(
        sessionStore: SessionStore,
        checkInStore: YamiboCheckInStore,
        settingsStore: SettingsStore = SettingsStore(),
        session: URLSession = YamiboNetworkConfiguration.makeSession(),
        promotionSession: URLSession = YamiboNetworkConfiguration.makeCookieIsolatedSession(),
        verificationDelayNanoseconds: UInt64 = 3_000_000_000,
        wafRecoverer: (any YamiboWAFChallengeRecovering)? = nil,
        makeRemote: (@Sendable (AccountSessionSnapshot) -> any YamiboCheckInRemoteOperating)? = nil
    ) {
        self.sessionStore = sessionStore
        self.checkInStore = checkInStore
        self.settingsStore = settingsStore
        self.verificationDelayNanoseconds = verificationDelayNanoseconds
        self.makeRemote = makeRemote ?? { snapshot in
            YamiboCheckInRemoteRepository(
                session: session, snapshot: snapshot, sessionStore: sessionStore,
                promotionSession: promotionSession, wafRecoverer: wafRecoverer
            )
        }
    }

    func checkInIfNeeded(force: Bool = false) async -> YamiboCheckInResult {
        await checkInWithDetails(force: force).result
    }

    func checkInWithDetails(force: Bool) async -> YamiboCheckInOutcome {
        guard let snapshot = try? await sessionStore.snapshot(),
              await sessionStore.isCurrentGeneration(snapshot.generation) else {
            return .init(result: .notAuthenticated, isCancelled: true)
        }
        let sessionState = snapshot.session
        guard sessionState.isLoggedIn, !sessionState.cookie.isEmpty else {
            return .init(result: .notAuthenticated)
        }
        if !force {
            let needsCheckIn = await checkInStore.needsCheckIn(session: sessionState)
            if !needsCheckIn { return .init(result: .skippedToday) }
        }

        let remote = makeRemote(snapshot)
        if await settingsStore.load().system.enhancedCheckInEnabled {
            remote.startPromotionVisit()
        }

        let page: YamiboCheckInPage
        do {
            page = try await remote.loadPage()
        } catch {
            return networkFailureOutcome(error)
        }

        switch page {
        case .alreadyCheckedIn:
            guard await sessionStore.isCurrentGeneration(snapshot.generation), !Task.isCancelled else {
                return networkFailureOutcome(CancellationError())
            }
            await checkInStore.markCheckedIn(session: sessionState)
            return .init(result: .alreadyCheckedInToday)
        case let .unavailable(details):
            return .init(result: .parseFailed, details: details)
        case let .available(url):
            do {
                try await remote.submit(at: url)
            } catch {
                return networkFailureOutcome(error)
            }
        }

        if verificationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: verificationDelayNanoseconds)
        }
        do {
            guard try await remote.verifyCheckIn() else {
                return .init(result: .verificationFailed)
            }
            guard await sessionStore.isCurrentGeneration(snapshot.generation), !Task.isCancelled else {
                throw CancellationError()
            }
            await checkInStore.markCheckedIn(session: sessionState)
            return .init(result: .success)
        } catch {
            return networkFailureOutcome(error)
        }
    }

    private func networkFailureOutcome(_ error: Error) -> YamiboCheckInOutcome {
        let cancelled = Task.isCancelled || LoadDiagnosticError.isCancellation(error)
        return YamiboCheckInOutcome(
            result: mapNetworkError(error),
            details: cancelled ? nil : LoadFailureDetails(error: error),
            isCancelled: cancelled,
            requiresSecurityVerification: LoadDiagnosticError.classificationError(error) as? YamiboError == .securityVerificationRequired
        )
    }

    private func mapNetworkError(_ error: Error) -> YamiboCheckInResult {
        if let yamiboError = LoadDiagnosticError.classificationError(error) as? YamiboError, yamiboError == .notAuthenticated {
            return .notAuthenticated
        }
        let message = (error as? LocalizedError)?.errorDescription ?? L10n.string("yamibo_check_in.network_failed")
        return .networkFailed(message.isEmpty ? L10n.string("yamibo_check_in.network_failed") : message)
    }

}

import Foundation

struct YamiboLoginResponse: Sendable {
    var requiresAdditionalVerification: Bool
    var failureMessage: String
}

protocol YamiboAccountRemoteOperating: Sendable {
    func fetchLoginForm() async throws -> YamiboLoginForm
    func submitLogin(_ request: YamiboLoginRequest, form: YamiboLoginForm, credentials: YamiboRequestCredentials) async throws -> YamiboLoginResponse
    func fetchProfile(
        credentials: YamiboRequestCredentials,
        handlesCookies: Bool,
        allowsWAFRecovery: Bool,
        validateSession: (@Sendable () async throws -> Void)?
    ) async throws -> YamiboProfile
    func signOut(credentials: YamiboRequestCredentials, formHash: String) async throws
}

enum YamiboCheckInPage: Sendable {
    case alreadyCheckedIn
    case available(URL)
    case unavailable(LoadFailureDetails)
}

/// Scoped to one account snapshot, including validation on every check-in request.
protocol YamiboCheckInRemoteOperating: Sendable {
    func loadPage() async throws -> YamiboCheckInPage
    func submit(at url: URL) async throws
    func verifyCheckIn() async throws -> Bool
    func startPromotionVisit()
}

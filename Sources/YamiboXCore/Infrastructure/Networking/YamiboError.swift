import Foundation

public enum YamiboError: LocalizedError, Equatable, Sendable {
    case invalidResponse(statusCode: Int?)
    case invalidImageData
    case unreadableBody
    case emptyHTML
    case parsingFailed(context: String)
    case floodControl
    case securityVerificationRequired
    case notAuthenticated
    case accountUIDUnavailable
    case loginFormUnavailable
    case loginFailed(String)
    case loginVerificationRequired
    case offline
    case searchCooldown(seconds: Int)
    case missingForumSearchToken
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidResponse(statusCode):
            if statusCode == 403 {
                return L10n.string("error.access_restricted")
            }
            if let statusCode {
                return L10n.string("error.invalid_response_with_status", statusCode)
            }
            return L10n.string("error.invalid_response")
        case .invalidImageData:
            return L10n.string("image.load_failed")
        case .unreadableBody:
            return L10n.string("error.unreadable_body")
        case .emptyHTML:
            return L10n.string("error.empty_html")
        case let .parsingFailed(context):
            return L10n.string("error.parsing_failed", context)
        case .floodControl:
            return L10n.string("error.flood_control")
        case .securityVerificationRequired:
            return L10n.string("error.security_verification_required")
        case .notAuthenticated:
            return L10n.string("error.not_authenticated")
        case .accountUIDUnavailable:
            return L10n.string("error.account_uid_unavailable")
        case .loginFormUnavailable:
            return L10n.string("error.login_form_unavailable")
        case let .loginFailed(message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L10n.string("error.login_failed")
                : message
        case .loginVerificationRequired:
            return L10n.string("error.login_verification_required")
        case .offline:
            return L10n.string("error.offline")
        case let .searchCooldown(seconds):
            return L10n.string("error.search_cooldown", seconds)
        case .missingForumSearchToken:
            return L10n.string("error.missing_forum_search_token")
        case let .underlying(message):
            return message
        }
    }
}

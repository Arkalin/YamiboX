import Foundation

/// Error layering after the domain split (this enum used to be the one
/// central bucket for every failure in the app):
///
/// - Transport & session (network responses, HTML parsing, login/session
///   state, search throttling) = `YamiboError` — this file.
/// - Favorite operations (add/delete a thread favorite, favorite a board)
///   = `FavoriteActionError` (Library/Domain/FavoriteActionError.swift).
/// - Persistence (stores, caches, encode/decode of local data)
///   = `YamiboPersistenceError` (Persistence/YamiboPersistenceError.swift),
///   which also preserves the underlying error chain that the old
///   `persistenceFailed(String)` case flattened away.
///
/// `underlying(String)` stays here: it is the transport layer's "wrap an
/// arbitrary lower-level failure into a displayable message" escape hatch.
public enum YamiboError: LocalizedError, Equatable, Sendable {
    case invalidResponse(statusCode: Int?)
    case invalidImageData
    case unreadableBody
    case emptyHTML
    case parsingFailed(context: String)
    case floodControl
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

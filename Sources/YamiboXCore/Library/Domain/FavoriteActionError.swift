import Foundation

/// Failure vocabulary for favorite operations (adding/deleting a thread
/// favorite, favoriting a forum board).
///
/// These cases used to live in `YamiboError`, which made the central
/// transport-layer enum a shotgun-surgery magnet: every favorites feature
/// change rippled into the networking module. They were extracted here so the
/// favorites domain owns its own error type; case names and the user-visible
/// `errorDescription` copy are migrated verbatim from the original
/// `YamiboError` cases.
public enum FavoriteActionError: LocalizedError, Equatable, Sendable {
    case missingFavoriteDeleteToken
    case missingFavoriteDeleteID
    case favoriteDeleteFailed
    case missingFavoriteAddToken
    case missingFavoriteThreadID
    case favoriteAddFailed
    case missingForumBoardFavoriteToken
    case forumBoardFavoriteFailed

    public var errorDescription: String? {
        switch self {
        case .missingFavoriteDeleteToken:
            return L10n.string("error.missing_favorite_delete_token")
        case .missingFavoriteDeleteID:
            return L10n.string("error.missing_favorite_delete_id")
        case .favoriteDeleteFailed:
            return L10n.string("error.favorite_delete_failed")
        case .missingFavoriteAddToken:
            return L10n.string("error.missing_favorite_add_token")
        case .missingFavoriteThreadID:
            return L10n.string("error.missing_favorite_thread_id")
        case .favoriteAddFailed:
            return L10n.string("error.favorite_add_failed")
        case .missingForumBoardFavoriteToken:
            return L10n.string("error.missing_forum_board_favorite_token")
        case .forumBoardFavoriteFailed:
            return L10n.string("error.forum_board_favorite_failed")
        }
    }
}

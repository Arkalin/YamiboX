import Foundation

public enum FavoriteActionError: LocalizedError, Equatable, Sendable {
    case missingFavoriteDeleteToken
    case missingFavoriteDeleteID
    case favoriteDeleteFailed
    case favoriteLookupIncomplete
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
        case .favoriteLookupIncomplete:
            return L10n.string("error.favorite_lookup_incomplete")
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

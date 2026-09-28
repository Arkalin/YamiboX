import Foundation

public protocol ForumThreadFavoriteRemoteOperating: Sendable {
    func addThreadFavorite(threadID: String, formHash: String?, resolveRemoteFavorite: Bool) async throws -> Favorite?
    func deleteFavorite(remoteFavoriteID: String) async throws
    func remoteFavorite(forThreadID threadID: String, maxPages: Int) async throws -> Favorite?
}

/// Remote operations required by the bidirectional favorite sync workflow.
public protocol FavoriteRemoteSyncOperating: Sendable {
    func fetchFavoritesPage(page: Int) async throws -> FavoriteRemotePage
    func currentFormHash() async throws -> String
    func addThreadFavorite(threadID: String, formHash: String?, resolveRemoteFavorite: Bool) async throws -> Favorite?
}

public protocol BoardFavoriteManaging: Sendable {
    func fetchBoardFavoritesPage(page: Int) async throws -> BoardFavoriteRemotePage
    func deleteFavorite(remoteFavoriteID: String) async throws
}

/// Assembly carries the combined capabilities; consumers request only their part.
public typealias FavoriteLibraryRemoteOperating = ForumThreadFavoriteRemoteOperating
    & FavoriteRemoteSyncOperating & BoardFavoriteManaging

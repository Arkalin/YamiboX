import Foundation

/// A favorited forum board from the remote list
/// (`home.php?mod=space&do=favorite&type=forum`). Board favorites are
/// display-and-manage-over-network only: unlike thread favorites there is no
/// local persistence or sync, so the model carries just what the remote page
/// shows.
public struct BoardFavorite: Hashable, Identifiable, Sendable {
    public let fid: String
    public let title: String
    /// The remote favorite record id (`favid`), required to delete the
    /// favorite. Missing when the page's delete link couldn't be parsed.
    public let remoteFavoriteID: String?

    public var id: String { fid }

    public init(fid: String, title: String, remoteFavoriteID: String? = nil) {
        self.fid = fid
        self.title = title
        self.remoteFavoriteID = remoteFavoriteID
    }
}

/// One parsed page of the remote board-favorite list, with page navigation
/// info.
public struct BoardFavoriteRemotePage: Sendable {
    public let boards: [BoardFavorite]
    public let currentPage: Int
    public let totalPages: Int

    public init(boards: [BoardFavorite], currentPage: Int, totalPages: Int) {
        self.boards = boards
        self.currentPage = max(1, currentPage)
        self.totalPages = max(1, totalPages)
    }
}

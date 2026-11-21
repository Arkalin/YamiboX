import Foundation

public struct BoardFavorite: Hashable, Identifiable, Sendable {
    public let fid: String
    public let title: String
    public let remoteFavoriteID: String?

    public var id: String { fid }

    public init(fid: String, title: String, remoteFavoriteID: String? = nil) {
        self.fid = fid
        self.title = title
        self.remoteFavoriteID = remoteFavoriteID
    }
}

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

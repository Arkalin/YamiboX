import Foundation

enum FavoritePageParseStatus: Sendable, Equatable {
    case recognizedEmpty
    case parsedContent
    case failed
    case uncertain
}

public struct FavoriteRemotePage: Sendable {
    public let favorites: [Favorite]
    public let currentPage: Int
    public let totalPages: Int

    public init(favorites: [Favorite], currentPage: Int, totalPages: Int) {
        self.favorites = favorites
        self.currentPage = max(1, currentPage)
        self.totalPages = max(1, totalPages)
    }
}

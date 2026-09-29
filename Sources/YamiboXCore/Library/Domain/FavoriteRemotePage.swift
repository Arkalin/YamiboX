import Foundation

/// Confidence reported by the HTML adapter before a remote page is admitted
/// to a repository operation. An empty array is not sufficient evidence of an
/// empty remote list: a page can also be rendered but structurally uncertain.
enum FavoritePageParseStatus: Sendable, Equatable {
    case recognizedEmpty
    case parsedContent
    case failed
    case uncertain
}

/// One parsed page of the remote favorite list, with page navigation info.
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

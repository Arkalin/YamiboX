import Foundation

public struct NovelDownloadPreparedSourcePage: Sendable {
    public var sourcePage: ForumThreadPage
    public var projection: NovelReaderProjection

    public init(sourcePage: ForumThreadPage, projection: NovelReaderProjection) {
        self.sourcePage = sourcePage
        self.projection = projection
    }
}

protocol NovelDownloadSourcePageLoading: Sendable {
    func loadNovelDownloadSourcePage(_ request: NovelDownloadWorkRequest) async throws -> NovelDownloadPreparedSourcePage
}

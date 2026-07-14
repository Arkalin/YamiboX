import Foundation

public struct NovelOfflineCachePreparedSourcePage: Sendable {
    public var sourcePage: ForumThreadPage
    public var projection: NovelReaderProjection

    public init(sourcePage: ForumThreadPage, projection: NovelReaderProjection) {
        self.sourcePage = sourcePage
        self.projection = projection
    }
}

protocol NovelOfflineCacheSourcePageLoading: Sendable {
    func loadNovelOfflineCacheSourcePage(_ request: NovelOfflineCacheWorkRequest) async throws -> NovelOfflineCachePreparedSourcePage
}

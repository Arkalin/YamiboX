import Foundation

/// I/O capabilities consumed by novel detail pages and supplied by app assembly.
public protocol NovelDetailDocumentLoading: Sendable {
    func loadPage(_ request: NovelPageRequest) async throws -> NovelReaderProjection
}

public protocol NovelDetailThreadPageLoading: Sendable {
    func cachedNovelThreadPage(context: NovelDetailLaunchContext, page: Int) async -> ForumThreadPage?
    func fetchNovelThreadPage(context: NovelDetailLaunchContext, page: Int) async throws -> ForumThreadPage
    func clearCachedThreadPages(thread: ThreadIdentity) async throws
    func storeNovelThreadPage(_ page: ForumThreadPage, context: NovelDetailLaunchContext, pageNumber: Int) async throws
}

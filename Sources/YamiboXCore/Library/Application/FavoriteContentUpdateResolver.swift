import Foundation

/// Bounded metadata refresh: first page plus, only for multi-page threads,
/// newest-first page. No full-thread or manga-directory traversal. Dates are
/// observed publication/edit times; fetching/checking never supplies a date.
public enum FavoriteContentUpdateResolver {
    public struct Snapshot: Sendable {
        public var firstPage: ForumThreadPage
        public var latestPage: ForumThreadPage
        public var contentUpdatedAt: Date?
    }

    public static func resolve(
        thread: ThreadIdentity,
        title: String,
        kind: FavoriteItemTargetKind,
        repository: any ThreadContentUpdatePageLoading
    ) async throws -> Snapshot {
        let first = try await repository.fetchContentUpdatePage(thread: thread, title: title, authorID: nil, reverse: false)
        try Task.checkCancellation()
        let root = first.posts.first { ["1#", "楼主", "樓主"].contains($0.floorText ?? "") } ?? first.posts.first
        let owner = root?.author.uid
        if kind == .mangaThread {
            // A manga favorite is a chapter. Its publication, not its edits,
            // replies, or the directory's refresh time, is the content date.
            return Snapshot(firstPage: first, latestPage: first, contentUpdatedAt: root.flatMap(FavoriteContentUpdateDateResolver.publicationDate))
        }
        let authorID = kind == .novelThread ? owner : nil
        guard kind != .novelThread || authorID != nil else {
            // Never seed an author-scoped baseline from an unscoped page.
            throw YamiboError.parsingFailed(context: L10n.string("parsing_context.novel_author_scope"))
        }
        let latest: ForumThreadPage
        if (first.pageNavigation?.totalPages ?? 1) > 1 {
            latest = try await repository.fetchContentUpdatePage(thread: thread, title: title, authorID: authorID, reverse: true)
        } else {
            latest = first
        }
        try Task.checkCancellation()
        var scopedLatest = latest
        // Fingerprints also consume this page. Exclude reader replies for a
        // novel and normalize reverse ordering before choosing the last post.
        scopedLatest.posts = latest.posts.filter { authorID == nil || $0.author.uid == authorID }.sorted {
            ($0.postID.count, $0.postID) < ($1.postID.count, $1.postID)
        }
        if authorID != nil { scopedLatest.totalReplies = nil }
        return Snapshot(
            firstPage: first, latestPage: scopedLatest,
            contentUpdatedAt: [FavoriteContentUpdateDateResolver.date(in: first, authorID: authorID),
                               FavoriteContentUpdateDateResolver.date(in: latest, authorID: authorID)].compactMap { $0 }.max()
        )
    }
}

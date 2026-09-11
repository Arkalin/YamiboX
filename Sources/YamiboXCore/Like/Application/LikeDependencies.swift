import Foundation

/// Dependency package the My Likes feature and both readers share to build
/// their capture services and list views from the same infrastructure.
///
/// Bookmarks ride along here rather than in a package of their own: every
/// consumer that needs one needs the other (the readers' bottom chrome and the
/// 书签与喜欢 panel show both), so a second parallel package would only add a
/// second parameter to thread through the same call sites.
public struct LikeDependencies: Sendable {
    public let likeStore: LikeStore
    public let likeImageStore: LikeImageStore
    public let bookmarkStore: BookmarkStore
    /// Resolves manga chapter order for the second-level Like list; manga
    /// Like Items don't store a chapter ordinal (see implementation-design §11).
    public let mangaDirectoryStore: MangaDirectoryStore
    /// Local-only source for backfilling chapter titles on legacy Like items.
    public let novelReaderCacheStore: NovelReaderProjectionStore

    public init(
        likeStore: LikeStore,
        likeImageStore: LikeImageStore,
        bookmarkStore: BookmarkStore,
        mangaDirectoryStore: MangaDirectoryStore,
        novelReaderCacheStore: NovelReaderProjectionStore
    ) {
        self.likeStore = likeStore
        self.likeImageStore = likeImageStore
        self.bookmarkStore = bookmarkStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.novelReaderCacheStore = novelReaderCacheStore
    }

    public func resolveChapterInfo(
        for items: [LikeItem],
        work: LikeWorkKey,
        mangaDirectory: MangaDirectory? = nil
    ) async -> [String: String] {
        let scopedItems = items.filter { $0.workKey == work }
        let titles: [String: String]
        switch work.kind {
        case .novel:
            titles = await LikeChapterInfoResolver.novelChapterInfo(
                for: scopedItems, threadID: work.id, cacheStore: novelReaderCacheStore
            )
        case .manga:
            let directory: MangaDirectory?
            if let mangaDirectory {
                directory = mangaDirectory
            } else if scopedItems.contains(where: { $0.chapterTitle == nil }) {
                directory = try? await mangaDirectoryStore.directory(named: work.id)
            } else {
                directory = nil
            }
            titles = LikeChapterInfoResolver.mangaChapterInfo(for: scopedItems, directory: directory)
        }
        let snapshots = scopedItems.compactMap { item -> LikeItem? in
            guard item.chapterTitle == nil, let title = titles[item.id] else { return nil }
            var snapshot = item
            snapshot.chapterTitle = title
            return snapshot
        }
        _ = try? await likeStore.resolveChapterTitles(snapshots)
        return titles
    }
}

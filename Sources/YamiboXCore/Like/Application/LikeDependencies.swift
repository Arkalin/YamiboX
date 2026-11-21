import Foundation

public struct LikeDependencies: Sendable {
    public let likeStore: LikeStore
    public let likeImageStore: LikeImageStore
    public let bookmarkStore: BookmarkStore
    public let mangaDirectoryStore: MangaDirectoryStore
    public let novelReaderCacheStore: any NovelReaderProjectionReading

    public var annotations: ReaderAnnotationService {
        ReaderAnnotationService(likeStore: likeStore, likeImageStore: likeImageStore, bookmarkStore: bookmarkStore)
    }

    public init(
        likeStore: LikeStore,
        likeImageStore: LikeImageStore,
        bookmarkStore: BookmarkStore,
        mangaDirectoryStore: MangaDirectoryStore,
        novelReaderCacheStore: any NovelReaderProjectionReading
    ) {
        self.likeStore = likeStore
        self.likeImageStore = likeImageStore
        self.bookmarkStore = bookmarkStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.novelReaderCacheStore = novelReaderCacheStore
    }

    public func backfillNovelChapterTitles(in projections: [NovelReaderProjection]) async {
        for projection in projections {
            await LikeChapterInfoResolver.backfillNovelChapterTitles(in: projection, store: likeStore)
        }
    }

    public func resolveChapterInfo(
        for items: [LikeItem],
        work: ReadingWorkKey,
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
                directory = try? await mangaDirectoryStore.directory(id: MangaDirectoryID(rawValue: work.id))
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

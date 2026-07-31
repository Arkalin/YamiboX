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
    /// Best-effort novel chapter-title lookup for Like item cards: a
    /// disk-cache-only read (no network), matched against a Like anchor's
    /// segment identity. Like anchors never persist a chapter title (same
    /// "resolve live" philosophy as `mangaDirectoryStore` above), so this can
    /// return nil on a cold cache and the card simply omits chapter info.
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
}

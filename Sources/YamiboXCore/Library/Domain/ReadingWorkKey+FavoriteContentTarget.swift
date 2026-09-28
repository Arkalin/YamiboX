public extension ReadingWorkKey {
    /// Annotation work identities are novel threads or resolved manga
    /// directories; ordinary and per-thread manga targets have no work key.
    init?(target: FavoriteContentTarget) {
        switch target {
        case let .novelThread(threadID):
            self = .novel(threadID: threadID)
        case let .mangaTitle(mangaID, _):
            self = .mangaTitle(directoryID: MangaDirectoryID(rawValue: mangaID))
        case .normalThread, .mangaThread:
            return nil
        }
    }
}

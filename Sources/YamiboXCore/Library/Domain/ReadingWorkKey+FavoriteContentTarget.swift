public extension ReadingWorkKey {
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

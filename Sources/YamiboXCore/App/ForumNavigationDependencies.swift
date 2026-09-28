import Foundation

/// Cross-feature packages used only when assembling navigation destinations.
public struct ForumDestinationDependencies: Sendable {
    public let novelDetail: NovelDetailDependencies
    public let mangaDetail: MangaDetailDependencies
    public let novelReader: NovelReaderDependencies
    public let mangaReader: MangaReaderDependencies

    public init(
        novelDetail: NovelDetailDependencies,
        mangaDetail: MangaDetailDependencies,
        novelReader: NovelReaderDependencies,
        mangaReader: MangaReaderDependencies
    ) {
        self.novelDetail = novelDetail
        self.mangaDetail = mangaDetail
        self.novelReader = novelReader
        self.mangaReader = mangaReader
    }
}

/// Navigation hosts carry both packages; individual forum pages receive only `forum`.
public struct ForumNavigationDependencies: Sendable {
    public let forum: ForumDependencies
    public let destinations: ForumDestinationDependencies

    public init(forum: ForumDependencies, destinations: ForumDestinationDependencies) {
        self.forum = forum
        self.destinations = destinations
    }
}

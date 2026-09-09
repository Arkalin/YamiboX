public struct MangaReadingResumeResolution: Hashable, Sendable {
    public let chapterTID: String
    public let displayTitle: String
    public let chapterView: Int
    public let initialPage: Int
    public let directoryName: String?

    public init(
        chapterTID: String,
        displayTitle: String,
        chapterView: Int,
        initialPage: Int,
        directoryName: String?
    ) {
        self.chapterTID = chapterTID
        self.displayTitle = displayTitle
        self.chapterView = chapterView
        self.initialPage = initialPage
        self.directoryName = directoryName
    }
}

/// Resolves a chapter-thread entrance without owning board settings or
/// launch-source metadata. Directory-identity entrances retain their own policy.
public struct MangaReadingResumeResolver: Sendable {
    private let readingProgressStore: ReadingProgressStore
    private let mangaDirectoryStore: any MangaDirectoryPersisting

    public init(
        readingProgressStore: ReadingProgressStore,
        mangaDirectoryStore: any MangaDirectoryPersisting
    ) {
        self.readingProgressStore = readingProgressStore
        self.mangaDirectoryStore = mangaDirectoryStore
    }

    public func resolve(
        threadID: String,
        title: String,
        isSmartModeEnabled: Bool,
        startsFromBeginning: Bool = false,
        fallbackChapterView: Int = 1
    ) async -> MangaReadingResumeResolution {
        let ownThreadProgress: MangaReadingProgressRecord?
        if startsFromBeginning {
            ownThreadProgress = nil
        } else {
            // A directory record can share the tid and be newer; only the
            // exact single-thread identity belongs to this fallback.
            ownThreadProgress = await readingProgressStore.load(for: .mangaThread(threadID: threadID))?.manga
        }
        let threadResolution = MangaReadingResumeResolution(
            chapterTID: ownThreadProgress?.chapterThreadID ?? threadID,
            displayTitle: title,
            chapterView: startsFromBeginning ? 1 : (ownThreadProgress?.chapterView ?? fallbackChapterView),
            initialPage: ownThreadProgress?.mangaPageIndex ?? 0,
            directoryName: nil
        )
        guard isSmartModeEnabled,
              let directory = try? await mangaDirectoryStore.directory(containingTID: threadID),
              let firstChapter = directory.chapters.first else {
            return threadResolution
        }

        let directoryProgress: MangaReadingProgressRecord?
        if startsFromBeginning {
            directoryProgress = nil
        } else {
            let target = FavoriteContentTarget(
                mangaID: directory.favoriteIdentity,
                mangaCleanBookName: directory.cleanBookName
            )
            directoryProgress = await readingProgressStore.load(for: target)?.manga
        }
        return MangaReadingResumeResolution(
            chapterTID: directoryProgress?.chapterThreadID ?? firstChapter.tid,
            displayTitle: directory.cleanBookName,
            chapterView: directoryProgress?.chapterView ?? firstChapter.view,
            initialPage: directoryProgress?.mangaPageIndex ?? 0,
            directoryName: directory.cleanBookName
        )
    }
}

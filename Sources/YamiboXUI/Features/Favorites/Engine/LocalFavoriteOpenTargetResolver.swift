import Foundation
import YamiboXCore

enum LocalFavoriteOpenTarget: Sendable {
    case novelDetail(NovelDetailLaunchContext)
    case mangaDetail(MangaDetailLaunchContext)
    case novelReader(NovelLaunchContext)
    case mangaReader(MangaLaunchContext)
    case nativeThread(url: URL, title: String)
}

struct LocalFavoriteOpenTargetResolver {
    let libraryStore: FavoriteLibraryStore
    let readingProgressStore: ReadingProgressStore
    let mangaDirectoryStore: any MangaDirectoryPersisting
    let settingsStore: SettingsStore

    init(
        libraryStore: FavoriteLibraryStore,
        readingProgressStore: ReadingProgressStore,
        mangaDirectoryStore: any MangaDirectoryPersisting,
        settingsStore: SettingsStore = SettingsStore()
    ) {
        self.libraryStore = libraryStore
        self.readingProgressStore = readingProgressStore
        self.mangaDirectoryStore = mangaDirectoryStore
        self.settingsStore = settingsStore
    }

    func openTarget(
        for item: FavoriteItem,
        mode: FavoriteLaunchMode = .resume,
        mangaScope: FavoriteMangaReadingScope = .boardDefault
    ) async throws -> LocalFavoriteOpenTarget? {
        let latestDocument = try await libraryStore.load()
        guard let latestItem = latestDocument.items.first(where: { $0.id == item.id }) else {
            return nil
        }
        let threadID = latestItem.target.threadID
        let settings = await settingsStore.load()
        let boardReader = settings.boardReader
        let opensDetails = mode == .preferred && settings.favorites.itemTapAction == .detail

        switch effectiveOpenKind(for: latestItem, boardReader: boardReader) {
        case .novelThread:
            let novel = try await readingProgressStore.load(threadID: threadID)?.novel
            if opensDetails {
                return .novelDetail(NovelDetailLaunchContext(
                    thread: ThreadIdentity(tid: threadID, fid: latestItem.forumID),
                    title: latestItem.resolvedDisplayTitle,
                    authorID: novel?.novelResumePoint?.authorID ?? novel?.authorID
                ))
            }
            let position = NovelReadingResumeResolver.resolve(progress: novel, startsFromBeginning: mode == .start)
            return .novelReader(
                NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: latestItem.resolvedDisplayTitle,
                    source: .favorites,
                    initialView: position.view,
                    authorID: position.authorID,
                    initialResumePoint: position.resumePoint,
                    forumID: latestItem.forumID
                )
            )
        case .normalThread:
            let url = YamiboRoute.threadByID(tid: threadID, page: 1, authorID: nil, reverse: false).url
            return .nativeThread(url: url, title: latestItem.resolvedDisplayTitle)
        case .mangaThread:
            let smartModeEnabled: Bool
            switch mangaScope {
            case .boardDefault:
                smartModeEnabled = boardReader.isSmartComicModeEnabled(forumID: latestItem.forumID)
            case .singleThread:
                smartModeEnabled = false
            }
            if opensDetails, smartModeEnabled {
                let directory = try await mangaDirectoryStore.directory(containingTID: threadID)
                let title = directory?.cleanBookName ?? MangaTitleCleaner.cleanBookName(latestItem.resolvedDisplayTitle)
                return .mangaDetail(MangaDetailLaunchContext(
                    thread: ThreadIdentity(tid: threadID, fid: latestItem.forumID),
                    title: title,
                    focusedChapterTID: threadID,
                    directoryNameHint: title
                ))
            }
            let resume = try await MangaReadingResumeResolver(
                readingProgressStore: readingProgressStore,
                mangaDirectoryStore: mangaDirectoryStore
            ).resolve(
                threadID: threadID,
                title: latestItem.resolvedDisplayTitle,
                isSmartModeEnabled: smartModeEnabled,
                startsFromBeginning: mode == .start
            )
            return .mangaReader(
                MangaLaunchContext(
                    originalThreadID: threadID,
                    chapterTID: resume.chapterTID,
                    displayTitle: resume.displayTitle,
                    source: .favorites,
                    chapterView: resume.chapterView,
                    initialPage: resume.initialPage,
                    directoryName: resume.directoryName,
                    directoryID: resume.directoryID,
                    downloadFavoriteID: latestItem.id,
                    isSmartModeEnabled: smartModeEnabled,
                    forumID: latestItem.forumID
                )
            )
        }
    }

    func openTarget(forMangaDirectoryID directoryID: MangaDirectoryID) async throws -> LocalFavoriteOpenTarget? {
        guard let directory = try await mangaDirectoryStore.directory(id: directoryID) else { return nil }
        let chapterTIDs = Set(directory.chapters.map(\.tid))
        let document = try await libraryStore.load()
        guard let item = document.items.first(where: {
            $0.target.kind == .mangaThread && chapterTIDs.contains($0.target.threadID)
        }) else {
            return nil
        }
        return try await openTarget(for: item, mode: .resume, mangaScope: .boardDefault)
    }

    private func effectiveOpenKind(
        for item: FavoriteItem,
        boardReader: BoardReaderSettings
    ) -> FavoriteItemTargetKind {
        guard let entry = boardReader.entry(forumID: item.forumID) else {
            return item.target.kind
        }
        switch entry.mode {
        case .normal:
            return .normalThread
        case .novel:
            return .novelThread
        case .manga:
            return .mangaThread
        }
    }
}

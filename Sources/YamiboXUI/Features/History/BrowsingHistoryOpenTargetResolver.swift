import Foundation
import YamiboXCore

enum BrowsingHistoryOpenTarget: Sendable {
    case novelReader(NovelLaunchContext)
    case mangaReader(MangaLaunchContext)
    case nativeThread(url: URL, title: String)
}

enum ReadingOpenOrigin: Sendable {
    case history
    case home

    var novelLaunchSource: NovelLaunchSource {
        switch self {
        case .history:
            return .history
        case .home:
            return .home
        }
    }

    var mangaLaunchSource: MangaLaunchSource {
        switch self {
        case .history:
            return .history
        case .home:
            return .home
        }
    }
}

struct ReadingOpenTargetResolver {
    let readingProgressStore: ReadingProgressStore
    let mangaDirectoryStore: any MangaDirectoryPersisting
    let historyWorkflow: BrowsingHistoryWorkflow

    func openTarget(
        for entry: BrowsingHistoryEntry,
        origin: ReadingOpenOrigin = .history,
        fallbackNovelView: Int? = nil,
        fallbackMangaView: Int = 1
    ) async throws -> BrowsingHistoryOpenTarget? {
        var entry = entry
        let snapshot = try await historyWorkflow.snapshot()
        let boardReader = snapshot.boardReader
        if let current = snapshot.entries.first(where: {
            $0.id == entry.id || (entry.lastVisitedThreadID != nil && $0.lastVisitedThreadID == entry.lastVisitedThreadID)
        }) {
            entry = current
        } else if let tid = entry.lastVisitedThreadID,
                  let directory = try? await mangaDirectoryStore.directory(containingTID: tid),
                  let current = snapshot.entries.first(where: {
                      $0.target.mangaID == directory.id.rawValue
                  }) {
            entry = current
        } else {
            return nil
        }

        switch entry.category(boardReader: boardReader) {
        case .normal:
            guard let threadID = entry.target.threadID ?? entry.chapterThreadID else { return nil }
            let url = YamiboRoute.threadByID(tid: threadID, page: 1, authorID: nil, reverse: false).url
            return .nativeThread(url: url, title: entry.title)

        case .novel:
            guard let threadID = entry.target.threadID ?? entry.chapterThreadID else { return nil }
            let novel = try await readingProgressStore.load(for: .novelThread(threadID: threadID))?.novel
            let position = NovelReadingResumeResolver.resolve(
                progress: novel, fallbackView: fallbackNovelView, fallbackAuthorID: entry.authorID
            )
            return .novelReader(
                NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: entry.title,
                    source: origin.novelLaunchSource,
                    initialView: position.view,
                    authorID: position.authorID,
                    initialResumePoint: position.resumePoint,
                    forumID: entry.forumID
                )
            )

        case .manga:
            let smartModeEnabled = boardReader.isSmartComicModeEnabled(forumID: entry.forumID)
            if case let .mangaTitle(mangaID, cleanBookName) = entry.target {
                return try await mangaTitleTarget(
                    directoryID: MangaDirectoryID(rawValue: mangaID),
                    cleanBookName: cleanBookName,
                    entry: entry,
                    smartModeEnabled: smartModeEnabled,
                    source: origin.mangaLaunchSource,
                    fallbackMangaView: fallbackMangaView
                )
            }
            guard let threadID = entry.target.threadID else { return nil }
            return try await mangaThreadTarget(
                threadID: threadID,
                entry: entry,
                smartModeEnabled: smartModeEnabled,
                source: origin.mangaLaunchSource,
                fallbackMangaView: fallbackMangaView
            )
        }
    }

    private func mangaThreadTarget(
        threadID: String,
        entry: BrowsingHistoryEntry,
        smartModeEnabled: Bool,
        source: MangaLaunchSource,
        fallbackMangaView: Int
    ) async throws -> BrowsingHistoryOpenTarget {
        let resume = try await MangaReadingResumeResolver(
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        ).resolve(
            threadID: threadID,
            title: entry.title,
            isSmartModeEnabled: smartModeEnabled,
            fallbackChapterView: fallbackMangaView
        )
        return .mangaReader(
            MangaLaunchContext(
                originalThreadID: threadID,
                chapterTID: resume.chapterTID,
                displayTitle: resume.displayTitle,
                source: source,
                chapterView: resume.chapterView,
                initialPage: resume.initialPage,
                directoryName: resume.directoryName,
                directoryID: resume.directoryID,
                isSmartModeEnabled: smartModeEnabled,
                forumID: entry.forumID
            )
        )
    }

    private func mangaTitleTarget(
        directoryID: MangaDirectoryID,
        cleanBookName: String,
        entry: BrowsingHistoryEntry,
        smartModeEnabled: Bool,
        source: MangaLaunchSource,
        fallbackMangaView: Int
    ) async throws -> BrowsingHistoryOpenTarget? {
        let directoryProgress = try await readingProgressStore.load(for: entry.target)?.manga
        guard let chapterTID = directoryProgress?.chapterThreadID ?? entry.chapterThreadID else {
            return nil
        }
        guard smartModeEnabled else {
            let ownThreadProgress = try await readingProgressStore.load(for: .mangaThread(threadID: chapterTID))?.manga
            return .mangaReader(
                MangaLaunchContext(
                    originalThreadID: chapterTID,
                    chapterTID: chapterTID,
                    displayTitle: entry.title,
                    source: source,
                    chapterView: ownThreadProgress?.chapterView ?? directoryProgress?.chapterView ?? fallbackMangaView,
                    initialPage: ownThreadProgress?.mangaPageIndex ?? 0,
                    directoryName: nil,
                    isSmartModeEnabled: false,
                    forumID: entry.forumID
                )
            )
        }
        let fallbackChapterView: Int
        if directoryProgress == nil,
           let directory = try? await mangaDirectoryStore.directory(containingTID: chapterTID) {
            fallbackChapterView = directory.chapters.first { $0.tid == chapterTID }?.view ?? 1
        } else {
            fallbackChapterView = 1
        }
        return .mangaReader(
            MangaLaunchContext(
                originalThreadID: chapterTID,
                chapterTID: chapterTID,
                displayTitle: cleanBookName,
                source: source,
                chapterView: directoryProgress?.chapterView ?? fallbackChapterView,
                initialPage: directoryProgress?.mangaPageIndex ?? 0,
                directoryName: cleanBookName,
                directoryID: directoryID,
                isSmartModeEnabled: true,
                forumID: entry.forumID
            )
        )
    }
}

typealias BrowsingHistoryOpenTargetResolver = ReadingOpenTargetResolver

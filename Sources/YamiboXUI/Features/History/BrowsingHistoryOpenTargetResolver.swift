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

/// Resolves a browsing-history row into a concrete open target, mirroring
/// `LocalFavoriteOpenTargetResolver`'s resume semantics per content form.
///
/// Which reader opens follows the board's *current* 阅读方式 configuration
/// (pluggable-reader-config R11/R13), through the same effective category the
/// history page displays (`BrowsingHistoryEntry.category(boardReader:)`): a
/// configured entry dictates the reader — 普通 opens the plain thread page,
/// 小说 the novel reader, 漫画 the manga path with the smart bit queried live
/// — known boards with no entry default to the plain reader, while unknown
/// ownership keeps the stored identity's reader. The shared workflow first
/// refreshes the row's identity and position to that same configuration:
///
/// - Normal threads open at page 1 with no explicit target — the thread
///   reader itself restores the saved page + floor anchor on every entrance
///   (browsing-history decision #8), so history adds nothing here.
/// - Novels resume via their `.novelThread` progress record; a row recorded
///   under another mode simply has none yet and starts fresh.
/// - Manga: stored `.mangaTitle` rows keep their directory-level resume
///   logic; every other stored identity goes through the single-thread
///   logic, which itself upgrades to the directory level when the board is
///   currently smart-on (decision #13).
struct ReadingOpenTargetResolver {
    let readingProgressStore: ReadingProgressStore
    let mangaDirectoryStore: any MangaDirectoryPersisting
    let settingsStore: SettingsStore
    var historyWorkflow: BrowsingHistoryWorkflow? = nil

    func openTarget(
        for entry: BrowsingHistoryEntry,
        origin: ReadingOpenOrigin = .history,
        fallbackNovelView: Int? = nil,
        fallbackMangaView: Int = 1
    ) async -> BrowsingHistoryOpenTarget? {
        // One settings snapshot backs both the category dispatch and the
        // manga smart bit, so a concurrent configuration change can't make
        // them disagree within a single resolve.
        let boardReader: BoardReaderSettings
        var entry = entry
        if let historyWorkflow {
            guard let snapshot = try? await historyWorkflow.snapshot() else { return nil }
            boardReader = snapshot.boardReader
            if let current = snapshot.entries.first(where: {
                $0.id == entry.id || (entry.lastVisitedThreadID != nil && $0.lastVisitedThreadID == entry.lastVisitedThreadID)
            }) {
                entry = current
            } else if let tid = entry.lastVisitedThreadID,
                      let directory = try? await mangaDirectoryStore.directory(containingTID: tid),
                      let current = snapshot.entries.first(where: {
                          $0.target == FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName)
                      }) {
                entry = current
            } else {
                return nil
            }
        } else {
            boardReader = await settingsStore.load().boardReader
        }

        switch entry.category(boardReader: boardReader) {
        case .normal:
            guard let threadID = entry.target.threadID ?? entry.chapterThreadID else { return nil }
            let url = YamiboRoute.threadByID(tid: threadID, page: 1, authorID: nil, reverse: false).url
            return .nativeThread(url: url, title: entry.title)

        case .novel:
            guard let threadID = entry.target.threadID ?? entry.chapterThreadID else { return nil }
            let novel = await readingProgressStore.load(for: .novelThread(threadID: threadID))?.novel
            let resumePoint = novel?.novelResumePoint
            return .novelReader(
                NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: entry.title,
                    source: origin.novelLaunchSource,
                    initialView: resumePoint?.view ?? novel?.lastView ?? fallbackNovelView,
                    authorID: resumePoint?.authorID ?? novel?.authorID ?? entry.authorID,
                    initialResumePoint: resumePoint,
                    forumID: entry.forumID
                )
            )

        case .manga:
            let smartModeEnabled = boardReader.isSmartComicModeEnabled(forumID: entry.forumID)
            if case let .mangaTitle(_, cleanBookName) = entry.target {
                return await mangaTitleTarget(
                    cleanBookName: cleanBookName,
                    entry: entry,
                    smartModeEnabled: smartModeEnabled,
                    source: origin.mangaLaunchSource,
                    fallbackMangaView: fallbackMangaView
                )
            }
            guard let threadID = entry.target.threadID else { return nil }
            return await mangaThreadTarget(
                threadID: threadID,
                entry: entry,
                smartModeEnabled: smartModeEnabled,
                source: origin.mangaLaunchSource,
                fallbackMangaView: fallbackMangaView
            )
        }
    }

    /// Single-thread manga open (stored `.mangaThread` rows — recorded while
    /// the board was off — plus normal/novel-recorded rows whose board is
    /// configured 漫画 now). If the board is smart-on *now*, resume at the
    /// directory level just like a `.mangaThread` favorite would; the next
    /// mode-on visit also absorbs such rows into directory-level ones
    /// (decision #13).
    private func mangaThreadTarget(
        threadID: String,
        entry: BrowsingHistoryEntry,
        smartModeEnabled: Bool,
        source: MangaLaunchSource,
        fallbackMangaView: Int
    ) async -> BrowsingHistoryOpenTarget {
        let resume = await MangaReadingResumeResolver(
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
                isSmartModeEnabled: smartModeEnabled,
                forumID: entry.forumID
            )
        )
    }

    /// Directory-level (`.mangaTitle`) row open.
    private func mangaTitleTarget(
        cleanBookName: String,
        entry: BrowsingHistoryEntry,
        smartModeEnabled: Bool,
        source: MangaLaunchSource,
        fallbackMangaView: Int
    ) async -> BrowsingHistoryOpenTarget? {
        let directoryProgress = await readingProgressStore.load(for: entry.target)?.manga
        guard let chapterTID = directoryProgress?.chapterThreadID ?? entry.chapterThreadID else {
            return nil
        }
        guard smartModeEnabled else {
            // Board toggled off since this directory-level row was written:
            // route by the current switch (PRD compatibility note) — open the
            // row's current chapter as a plain single thread reading its own
            // `.mangaThread` progress.
            let ownThreadProgress = await readingProgressStore.load(for: .mangaThread(threadID: chapterTID))?.manga
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
        // Progress can have been cleared since this row was written; the
        // chapter's real `view` still matters for multi-view threads, so
        // fall back to the directory's own metadata like the favorites
        // resolver does.
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
                isSmartModeEnabled: true,
                forumID: entry.forumID
            )
        )
    }
}

typealias BrowsingHistoryOpenTargetResolver = ReadingOpenTargetResolver

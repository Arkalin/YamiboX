import Foundation
import YamiboXCore

enum BrowsingHistoryOpenTarget: Sendable {
    case novelReader(NovelLaunchContext)
    case mangaReader(MangaLaunchContext)
    case nativeThread(url: URL, title: String)
}

/// Resolves a browsing-history row into a concrete open target, mirroring
/// `LocalFavoriteOpenTargetResolver`'s resume semantics per content form.
///
/// Which reader opens follows the board's *current* 阅读方式 configuration
/// (pluggable-reader-config R11/R13), through the same effective category the
/// history page displays (`BrowsingHistoryEntry.category(boardReader:)`): a
/// configured entry dictates the reader — 普通 opens the plain thread page,
/// 小说 the novel reader, 漫画 the manga path with the smart bit queried live
/// — while rows on boards with no entry (never configured, or no fid
/// recorded) keep their stored identity's reader:
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
struct BrowsingHistoryOpenTargetResolver {
    let readingProgressStore: ReadingProgressStore
    let mangaDirectoryStore: any MangaDirectoryPersisting
    let settingsStore: SettingsStore

    func openTarget(for entry: BrowsingHistoryEntry) async -> BrowsingHistoryOpenTarget? {
        // One settings snapshot backs both the category dispatch and the
        // manga smart bit, so a concurrent configuration change can't make
        // them disagree within a single resolve.
        let boardReader = await settingsStore.load().boardReader

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
                    source: .history,
                    initialView: resumePoint?.view ?? novel?.lastView,
                    authorID: resumePoint?.authorID ?? novel?.authorID ?? entry.authorID,
                    initialResumePoint: resumePoint
                )
            )

        case .manga:
            let smartModeEnabled = boardReader.isSmartComicModeEnabled(forumID: entry.forumID)
            if case let .mangaTitle(_, cleanBookName) = entry.target {
                return await mangaTitleTarget(
                    cleanBookName: cleanBookName,
                    entry: entry,
                    smartModeEnabled: smartModeEnabled
                )
            }
            guard let threadID = entry.target.threadID else { return nil }
            return await mangaThreadTarget(
                threadID: threadID,
                entry: entry,
                smartModeEnabled: smartModeEnabled
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
        smartModeEnabled: Bool
    ) async -> BrowsingHistoryOpenTarget {
        let ownThreadProgress = await readingProgressStore.load(for: .mangaThread(threadID: threadID))?.manga
        guard smartModeEnabled else {
            return .mangaReader(
                MangaLaunchContext(
                    originalThreadID: threadID,
                    chapterTID: ownThreadProgress?.chapterThreadID ?? threadID,
                    displayTitle: entry.title,
                    source: .history,
                    chapterView: ownThreadProgress?.chapterView ?? 1,
                    initialPage: ownThreadProgress?.mangaPageIndex ?? 0,
                    directoryName: nil,
                    isSmartModeEnabled: false,
                    forumID: entry.forumID
                )
            )
        }
        guard let directory = try? await mangaDirectoryStore.directory(containingTID: threadID),
              let firstChapter = directory.chapters.first else {
            return .mangaReader(
                MangaLaunchContext(
                    originalThreadID: threadID,
                    chapterTID: ownThreadProgress?.chapterThreadID ?? threadID,
                    displayTitle: entry.title,
                    source: .history,
                    chapterView: ownThreadProgress?.chapterView ?? 1,
                    initialPage: ownThreadProgress?.mangaPageIndex ?? 0,
                    directoryName: nil,
                    isSmartModeEnabled: true,
                    forumID: entry.forumID
                )
            )
        }
        let directoryTarget = FavoriteContentTarget(
            mangaID: directory.favoriteIdentity,
            mangaCleanBookName: directory.cleanBookName
        )
        let directoryProgress = await readingProgressStore.load(for: directoryTarget)?.manga
        return .mangaReader(
            MangaLaunchContext(
                originalThreadID: threadID,
                chapterTID: directoryProgress?.chapterThreadID ?? firstChapter.tid,
                displayTitle: directory.cleanBookName,
                source: .history,
                chapterView: directoryProgress?.chapterView ?? firstChapter.view,
                initialPage: directoryProgress?.mangaPageIndex ?? 0,
                directoryName: directory.cleanBookName,
                isSmartModeEnabled: true,
                forumID: entry.forumID
            )
        )
    }

    /// Directory-level (`.mangaTitle`) row open.
    private func mangaTitleTarget(
        cleanBookName: String,
        entry: BrowsingHistoryEntry,
        smartModeEnabled: Bool
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
                    source: .history,
                    chapterView: ownThreadProgress?.chapterView ?? directoryProgress?.chapterView ?? 1,
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
                source: .history,
                chapterView: directoryProgress?.chapterView ?? fallbackChapterView,
                initialPage: directoryProgress?.mangaPageIndex ?? 0,
                directoryName: cleanBookName,
                isSmartModeEnabled: true,
                forumID: entry.forumID
            )
        )
    }
}

import Foundation
import YamiboXCore

enum LocalFavoriteOpenTarget: Sendable {
    case novelDetail(NovelDetailLaunchContext)
    case mangaDetail(MangaDetailLaunchContext)
    case novelReader(NovelLaunchContext)
    case mangaReader(MangaLaunchContext)
    case nativeThread(url: URL, title: String)
}

/// Resolves a favorite using its latest stored metadata, settings and progress.
/// Preferred card taps may open details; explicit resume/start always read.
///
/// Manga reading retains the existing resume policy. Per decision #15's 2026-07-08
/// update, which progress record backs the resume position depends on
/// whether the favorite's board currently has Smart Comic Mode on:
/// - Mode on: resume via the directory-level `.mangaTitle` record. The
///   `MangaDirectory` this thread belongs to is looked up by tid (a bare
///   `.mangaThread(threadID:)` favorite doesn't itself carry a
///   cleanBookName/mangaID); falls back to the directory's earliest chapter
///   if the directory has no progress record yet, or to this thread's own
///   `.mangaThread` progress if the directory has never even been resolved
///   locally (e.g. a favorite synced in from another device that was never
///   opened here — decision #12 never triggers resolution on its own).
/// - Mode off: resume via this thread's own `.mangaThread` progress record
///   directly — no directory lookup at all, exactly like a normal thread.
///
/// `mangaScope: .singleThread` forces that same mode-off path without
/// consulting the board switch at all — the "查看归档收藏" archive page opens
/// its members this way, matching how it renders them as ordinary non-smart
/// cards (see `FavoriteMangaReadingScope`).
///
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
        guard let threadID = latestItem.target.threadID else { return nil }
        // One settings snapshot backs both the effective-kind dispatch and
        // the manga path's smart bit, so a concurrent configuration change
        // can't make the two disagree within a single resolve.
        let settings = await settingsStore.load()
        let boardReader = settings.boardReader
        let opensDetails = mode == .preferred && settings.favorites.itemTapAction == .detail

        switch effectiveOpenKind(for: latestItem, boardReader: boardReader) {
        case .novelThread:
            let novel = await readingProgressStore.load(threadID: threadID)?.novel
            if opensDetails {
                return .novelDetail(NovelDetailLaunchContext(
                    thread: ThreadIdentity(tid: threadID, fid: latestItem.forumID),
                    title: latestItem.resolvedDisplayTitle,
                    authorID: novel?.novelResumePoint?.authorID ?? novel?.authorID
                ))
            }
            let resumePoint = mode == .start ? nil : novel?.novelResumePoint
            return .novelReader(
                NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: latestItem.resolvedDisplayTitle,
                    source: .favorites,
                    initialView: mode == .start ? 1 : (resumePoint?.view ?? novel?.lastView),
                    authorID: resumePoint?.authorID ?? novel?.authorID,
                    initialResumePoint: resumePoint,
                    forumID: latestItem.forumID
                )
            )
        case .normalThread:
            let url = YamiboRoute.threadByID(tid: threadID, page: 1, authorID: nil, reverse: false).url
            return .nativeThread(url: url, title: latestItem.resolvedDisplayTitle)
        case .mangaThread:
            // `.singleThread` scope short-circuits to the mode-off path
            // below without consulting the board switch at all — the archive
            // page's tapped member must open as exactly the thread its
            // non-smart card shows, not re-enter the merged directory.
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
            let resume = await MangaReadingResumeResolver(
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
                    offlineCacheFavoriteID: latestItem.id,
                    isSmartModeEnabled: smartModeEnabled,
                    forumID: latestItem.forumID
                )
            )
        }
    }

    /// Re-derives an open target for a smart-manga update event, which only
    /// ever carries a `cleanBookName` (no pointer to one specific favorite —
    /// detection is per-directory, see `FavoriteUpdateTargetKey
    /// .mangaDirectory`). Finds any favorited `.mangaThread` chapter whose
    /// tid currently resolves into this directory and routes it through the
    /// same mode-on resume path a merged smart-manga card's tap already
    /// uses, rather than reimplementing directory-to-reader resolution here.
    /// Returns nil (never throws for this specific case) when no such
    /// favorite exists any more — the caller falls back to whatever it
    /// already does for a deleted favorite.
    func openTarget(forMangaDirectoryCleanBookName cleanBookName: String) async throws -> LocalFavoriteOpenTarget? {
        guard let directory = try await mangaDirectoryStore.directory(named: cleanBookName) else { return nil }
        let chapterTIDs = Set(directory.chapters.map(\.tid))
        let document = try await libraryStore.load()
        guard let item = document.items.first(where: {
            $0.target.kind == .mangaThread && chapterTIDs.contains($0.target.threadID ?? "")
        }) else {
            return nil
        }
        return try await openTarget(for: item, mode: .resume, mangaScope: .boardDefault)
    }

    /// Which reader a favorite opens with follows the board's *current*
    /// 阅读方式 configuration, not the kind stamped into the item at add
    /// time (pluggable-reader-config R11): a board entry configured 小说
    /// opens the novel reader, 漫画 opens the manga path (smart bit queried
    /// live as before), and an explicit 普通 entry forces the plain thread
    /// reader (R12 — switching a board back to 普通 writes a `.normal` entry
    /// precisely so this dispatch can honor it). Only when the item's board
    /// has NO entry — never-configured boards and items with no `forumID`
    /// (older/unresolved metadata) — does the stored kind decide, preserving
    /// content-type-derived kinds (a novel-TYPE favorite stays a novel even
    /// on an unconfigured board) and the decided mode-off `.mangaThread`
    /// behavior (still rendered by the manga reader, decision #2/#15).
    /// Stored kinds themselves are never rewritten (decision #5) — this is
    /// purely an open-time dispatch.
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

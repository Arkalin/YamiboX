import Foundation
import YamiboXCore

enum LocalFavoriteOpenTarget: Sendable {
    case novelReader(NovelLaunchContext)
    case mangaReader(MangaLaunchContext)
    case nativeThread(url: URL, title: String)
}

/// Resolves a favorite item into a concrete reader launch target, combining
/// the latest stored item with its reading progress.
///
/// `.mangaThread` favorites always resolve to the reader directly (mirroring
/// the pre-refactor `.mangaTitle` behavior of skipping the forum detail page)
/// — see smart-comic-mode design decision #7. Per decision #15's 2026-07-08
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
/// TODO(Phase F): favorites now compute virtual merged-directory grouping
/// (`LocalFavoriteLibraryProjection.cards`/`FavoriteCardProjection
/// .mangaDirectory`/`.mergedMembers`), but this resolver still only knows
/// about individual `FavoriteItem`s. A tap on a *merged card* should
/// presumably resolve through here using `mangaDirectory`'s identity
/// directly (`FavoriteContentTarget(mangaID: directory.favoriteIdentity,
/// mangaCleanBookName: directory.cleanBookName)`, the same key
/// `mangaDirectoryResumeTarget` below already reads) rather than picking one
/// member's tid and going through the existing single-item path — Phase F's
/// UI work needs to decide how it calls into this resolver for a merged card
/// before this can be filled in.
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
        let boardReader = await settingsStore.load().boardReader

        switch effectiveOpenKind(for: latestItem, boardReader: boardReader) {
        case .novelThread:
            let novel = await readingProgressStore.load(threadID: threadID)?.novel
            let resumePoint = mode == .start ? nil : novel?.novelResumePoint
            return .novelReader(
                NovelLaunchContext(
                    threadID: threadID,
                    threadTitle: latestItem.resolvedDisplayTitle,
                    source: .favorites,
                    initialView: mode == .start ? 1 : (resumePoint?.view ?? novel?.lastView),
                    authorID: resumePoint?.authorID ?? novel?.authorID,
                    initialResumePoint: resumePoint
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
            // Unlike the old `.mangaTitle` merged identity, every
            // `.mangaThread` favorite already carries a real chapter tid, so
            // there is always a chapter to open — falling back to this
            // favorite's own thread at page 0 replaces the old
            // `mangaTitleUnresolved` failure mode, which can no longer occur.
            //
            // Mode off (or `.singleThread` scope): "从头打开" just resets this
            // one thread's own page to 0, matching how such a card renders —
            // a single, standalone chapter with no directory to speak of.
            guard mode != .start else {
                guard smartModeEnabled else {
                    return .mangaReader(
                        MangaLaunchContext(
                            originalThreadID: threadID,
                            chapterTID: threadID,
                            displayTitle: latestItem.resolvedDisplayTitle,
                            source: .favorites,
                            initialPage: 0,
                            directoryName: nil,
                            offlineCacheFavoriteID: latestItem.id,
                            isSmartModeEnabled: false,
                            forumID: latestItem.forumID
                        )
                    )
                }
                // Mode on: the card this button lives on shows the *merged*
                // directory, so "从头打开" must jump to the directory's actual
                // first chapter — not just reset the representative member's
                // own tid to page 0, which for an already-parsed directory is
                // frequently a different chapter than #1 (the representative
                // item is whichever member was favorited earliest, not
                // necessarily the directory's first chapter).
                return await mangaDirectoryStartTarget(threadID: threadID, item: latestItem)
            }
            // Deliberately an exact id lookup (`FavoriteContentTarget
            // .mangaThread(threadID:)`, not the generic OR-based
            // `load(threadID:)`): a directory-level `.mangaTitle` record can
            // legitimately share this same tid in its `thread_id`/
            // `manga_chapter_thread_id` columns (e.g. this was the
            // currently-read chapter during a prior mode-on session), and
            // `load(threadID:)` would happily return whichever row was
            // updated more recently regardless of kind. Mode-off resume must
            // never pick up that stale directory-level record even by
            // coincidence — see smart-comic-mode design decision #15's note
            // that the two `.mangaThread` id formats are kept identical
            // specifically so this lookup is precise.
            let ownThreadProgress = await readingProgressStore.load(for: .mangaThread(threadID: threadID))?.manga
            guard smartModeEnabled else {
                return .mangaReader(
                    MangaLaunchContext(
                        originalThreadID: threadID,
                        chapterTID: ownThreadProgress?.chapterThreadID ?? threadID,
                        displayTitle: latestItem.resolvedDisplayTitle,
                        source: .favorites,
                        chapterView: ownThreadProgress?.chapterView ?? 1,
                        initialPage: ownThreadProgress?.mangaPageIndex ?? 0,
                        directoryName: nil,
                        offlineCacheFavoriteID: latestItem.id,
                        isSmartModeEnabled: false,
                        forumID: latestItem.forumID
                    )
                )
            }
            return await mangaDirectoryResumeTarget(
                threadID: threadID,
                item: latestItem,
                ownThreadProgress: ownThreadProgress
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

    /// Mode-on `.mangaThread` resume (decision #15/#7): looks up the
    /// `MangaDirectory` this chapter thread belongs to and resumes via its
    /// single upserted `.mangaTitle` record, falling back to the directory's
    /// earliest chapter when there's no progress yet. If the directory has
    /// never been resolved locally at all, falls back to this thread's own
    /// `.mangaThread` progress (still launching with `isSmartModeEnabled:
    /// true` so the reader resolves a real directory on this open).
    private func mangaDirectoryResumeTarget(
        threadID: String,
        item: FavoriteItem,
        ownThreadProgress: MangaReadingProgressRecord?
    ) async -> LocalFavoriteOpenTarget {
        guard let directory = try? await mangaDirectoryStore.directory(containingTID: threadID),
              let firstChapter = directory.chapters.first else {
            return .mangaReader(
                MangaLaunchContext(
                    originalThreadID: threadID,
                    chapterTID: ownThreadProgress?.chapterThreadID ?? threadID,
                    displayTitle: item.resolvedDisplayTitle,
                    source: .favorites,
                    chapterView: ownThreadProgress?.chapterView ?? 1,
                    initialPage: ownThreadProgress?.mangaPageIndex ?? 0,
                    directoryName: nil,
                    offlineCacheFavoriteID: item.id,
                    isSmartModeEnabled: true,
                    forumID: item.forumID
                )
            )
        }

        let directoryTarget = FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName)
        let directoryProgress = await readingProgressStore.load(for: directoryTarget)?.manga
        return .mangaReader(
            MangaLaunchContext(
                originalThreadID: threadID,
                chapterTID: directoryProgress?.chapterThreadID ?? firstChapter.tid,
                displayTitle: directory.cleanBookName,
                source: .favorites,
                chapterView: directoryProgress?.chapterView ?? firstChapter.view,
                initialPage: directoryProgress?.mangaPageIndex ?? 0,
                directoryName: directory.cleanBookName,
                offlineCacheFavoriteID: item.id,
                isSmartModeEnabled: true,
                forumID: item.forumID
            )
        )
    }

    /// Mode-on `.mangaThread` "从头打开" (open from beginning): looks up the
    /// `MangaDirectory` this chapter thread belongs to and always opens its
    /// first chapter at page 0, ignoring any existing reading progress. If
    /// the directory has never been resolved locally at all, falls back to
    /// this favorite's own thread at page 0 (still launching with
    /// `isSmartModeEnabled: true` so the reader resolves a real directory on
    /// this open, matching `mangaDirectoryResumeTarget`'s same fallback).
    private func mangaDirectoryStartTarget(
        threadID: String,
        item: FavoriteItem
    ) async -> LocalFavoriteOpenTarget {
        guard let directory = try? await mangaDirectoryStore.directory(containingTID: threadID),
              let firstChapter = directory.chapters.first else {
            return .mangaReader(
                MangaLaunchContext(
                    originalThreadID: threadID,
                    chapterTID: threadID,
                    displayTitle: item.resolvedDisplayTitle,
                    source: .favorites,
                    initialPage: 0,
                    directoryName: nil,
                    offlineCacheFavoriteID: item.id,
                    isSmartModeEnabled: true,
                    forumID: item.forumID
                )
            )
        }

        return .mangaReader(
            MangaLaunchContext(
                originalThreadID: threadID,
                chapterTID: firstChapter.tid,
                displayTitle: directory.cleanBookName,
                source: .favorites,
                chapterView: firstChapter.view,
                initialPage: 0,
                directoryName: directory.cleanBookName,
                offlineCacheFavoriteID: item.id,
                isSmartModeEnabled: true,
                forumID: item.forumID
            )
        )
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

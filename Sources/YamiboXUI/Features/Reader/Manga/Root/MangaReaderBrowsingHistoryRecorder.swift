import Foundation
import YamiboXCore

/// Owns the manga reader's browsing-history row for the current session:
/// records once on load, then keeps the row's identity in sync as the
/// directory identity or title changes mid-session. Pure bookkeeping over
/// the presentation it is handed — it publishes nothing, so it lives
/// outside the view model as a plain collaborator.
@MainActor
final class MangaReaderBrowsingHistoryRecorder {
    /// Reading context supplied by the owning view model.
    struct Reading {
        var currentDirectoryFavoriteIdentity: @MainActor () -> String?
        var makeBrowsingHistoryStore: @Sendable () -> BrowsingHistoryStore?
    }

    private let context: MangaLaunchContext
    private let reading: Reading
    /// `"\(entry.id)|\(entry.title)"` of the last browsing-history row this
    /// session recorded — re-records when the directory identity or title
    /// changes mid-session (synthetic directory resolving into a real one,
    /// or an in-reader rename), absorbing the superseded row by its old id.
    private var recordedBrowsingHistoryKey: String?
    private var recordedBrowsingHistoryEntryID: String?

    init(context: MangaLaunchContext, reading: Reading) {
        self.context = context
        self.reading = reading
    }

    /// Records this session's browsing-history row once `.loaded` (decision
    /// #5's "打开即记"), then keeps the row's *identity* in sync: the
    /// directory identity can change mid-session (a synthetic
    /// single-chapter directory resolving into a real one via the automatic
    /// update, or an in-reader rename), and the debounced
    /// `updatePosition` refreshes would otherwise target a row id that no
    /// longer matches — freezing the old row and spawning a duplicate on
    /// the next open. Re-recording under the new identity absorbs the
    /// superseded row by its old id. Called from `prepare()` and from
    /// `publishPresentation` (identity-stable page turns early-return on the
    /// key check).
    ///
    /// Identity forks on `context.isSmartModeEnabled` — never on a proxy
    /// signal like a non-nil directory name, which a mode-off
    /// pseudo-directory also produces (the trap three smart-comic-mode
    /// phases each hit once):
    /// - Mode on: one directory-level `.mangaTitle` row per manga (decision
    ///   #2), absorbing the directory members' single-thread rows (decision
    ///   #13) — the loaded directory panel has the member list.
    /// - Mode off: this thread's own `.mangaThread` row, exactly like a
    ///   normal post (smart-comic-mode "mode off = plain thread" principle).
    /// Position/chapter refreshes ride the debounced progress saves via
    /// `FavoriteLibraryProgressSyncAdapter`. Preview sessions never record.
    func syncRecordIfNeeded(presentation: MangaReaderPresentation) {
        guard !context.isPreview,
              case let .loaded(loaded) = presentation.state else {
            return
        }
        let currentPage = loaded.currentPage
        let entry: BrowsingHistoryEntry
        let absorbedThreadIDs: [String]
        if context.isSmartModeEnabled {
            let cleanBookName = MangaReaderViewModel.normalizedDirectoryName(loaded.directoryTitle)
                ?? MangaReaderViewModel.normalizedDirectoryName(context.directoryName)
                ?? context.displayTitle
            let target = FavoriteContentTarget(
                mangaID: reading.currentDirectoryFavoriteIdentity() ?? cleanBookName,
                mangaCleanBookName: cleanBookName
            )
            entry = BrowsingHistoryEntry(
                target: target,
                title: cleanBookName,
                forumID: context.forumID,
                pageIndex: currentPage?.localIndex,
                pageCount: currentPage?.chapterPageCount,
                chapterTitle: currentPage?.chapterTitle,
                chapterThreadID: currentPage?.tid ?? context.chapterTID,
                lastVisitTime: .now
            )
            absorbedThreadIDs = loaded.directoryPanel.displayChapters.map(\.tid)
        } else {
            entry = BrowsingHistoryEntry(
                target: .mangaThread(threadID: context.chapterTID),
                title: context.displayTitle,
                forumID: context.forumID,
                pageIndex: currentPage?.localIndex,
                pageCount: currentPage?.chapterPageCount,
                chapterTitle: currentPage?.chapterTitle,
                lastVisitTime: .now
            )
            absorbedThreadIDs = []
        }

        let recordKey = "\(entry.id)|\(entry.title)"
        guard recordKey != recordedBrowsingHistoryKey else { return }
        let supersededEntryID = recordedBrowsingHistoryEntryID.flatMap { $0 == entry.id ? nil : $0 }
        recordedBrowsingHistoryKey = recordKey
        recordedBrowsingHistoryEntryID = entry.id
        guard let browsingHistoryStore = reading.makeBrowsingHistoryStore() else { return }
        Task {
            do {
                try await browsingHistoryStore.record(
                    entry,
                    absorbingThreadIDs: absorbedThreadIDs,
                    absorbingEntryIDs: supersededEntryID.map { [$0] } ?? []
                )
            } catch {
                YamiboLog.reader.warning("Failed to record manga browsing-history visit for \(entry.id, privacy: .public): \(error)")
            }
        }
    }

    /// Reader-session teardown (retryInitialLoad): forget the recorded row
    /// so the fresh session records again ("打开即记" applies per session).
    func reset() {
        recordedBrowsingHistoryKey = nil
        recordedBrowsingHistoryEntryID = nil
    }
}

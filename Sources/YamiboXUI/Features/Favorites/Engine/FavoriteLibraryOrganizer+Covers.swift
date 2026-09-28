import Foundation
import YamiboXCore

extension FavoriteLibraryOrganizer {

    // MARK: - Manga directory grouping (smart-comic-mode decision #3/#5)

    /// Resolves the tid → `MangaDirectory` map virtual favorites grouping
    /// needs, in one batched read — the design doc's performance
    /// constraint #1. `items` is first narrowed in memory (no I/O) to
    /// mode-on `.mangaThread` favorites only, using the *explicit*
    /// `BoardReaderSettings.isSmartComicModeEnabled(forumID:)` check (never a proxy
    /// signal — this exact class of bug bit three earlier phases), before
    /// the `MangaDirectoryBatchReading.directories(containingTIDs:)` call.
    /// Called only from `load()`/`reload()`, never from
    /// `refreshDerivedState()` or any SwiftUI-observed computed property —
    /// performance constraint #2.
    func resolveMangaDirectories(
        for items: [FavoriteItem],
        boardReaderSettings: BoardReaderSettings
    ) async -> [String: MangaDirectory] {
        guard let mangaDirectoryStore else { return [:] }
        let candidateTIDs = items.compactMap { item -> String? in
            guard item.target.kind == .mangaThread,
                  boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID) else {
                return nil
            }
            return item.target.threadID
        }
        guard !candidateTIDs.isEmpty else { return [:] }
        do {
            return try await mangaDirectoryStore.directories(containingTIDs: candidateTIDs)
        } catch {
            YamiboLog.persistence.warning("Failed to resolve manga directories for favorites grouping; showing manga favorites standalone this load: \(error.localizedDescription)")
            return [:]
        }
    }

    @discardableResult
    func toggleTextCover(for card: FavoriteCardProjection) async -> Bool {
        guard let key = card.contentCoverKey else { return false }
        do {
            let forced = try await covers.toggleTextCover(for: key)
            scheduleMangaCoverBackfill(for: document.items)
            transientMessage = forced
                ? L10n.string("cover.use_text_cover_success_message")
                : L10n.string("cover.use_image_cover_success_message")
            return true
        } catch {
            YamiboLog.library.error("Failed to toggle text cover for \(card.item.id): \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }

    func scheduleMangaCoverBackfill(for items: [FavoriteItem]) {
        covers.scheduleBackfill(for: LocalFavoriteLibraryProjection.mangaDirectoryGroups(
            for: items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        ))
    }
}

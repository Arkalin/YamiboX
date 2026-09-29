import Foundation
import YamiboXCore

extension FavoriteLibraryOrganizer {

    // MARK: - Manga directory grouping (smart-comic-mode decision #3/#5)

    /// Resolves the tid → `MangaDirectory` map virtual favorites grouping
    /// needs, in one batched read. Retain all manga identities for unread
    /// indicators, then return only mode-on members for virtual grouping.
    /// Disabling smart presentation must not hide existing unread events.
    /// Called only from `load()`/`reload()`, never from
    /// `refreshDerivedState()` or any SwiftUI-observed computed property —
    /// performance constraint #2.
    func resolveMangaDirectories(
        for items: [FavoriteItem],
        boardReaderSettings: BoardReaderSettings
    ) async -> [String: MangaDirectory] {
        guard let mangaDirectoryStore else {
            unreadMangaDirectoriesByTID = [:]
            return [:]
        }
        let candidateTIDs = items.compactMap { item -> String? in
            guard item.target.kind == .mangaThread else {
                return nil
            }
            return item.target.threadID
        }
        guard !candidateTIDs.isEmpty else {
            unreadMangaDirectoriesByTID = [:]
            return [:]
        }
        do {
            let directories = try await mangaDirectoryStore.directories(containingTIDs: candidateTIDs)
            unreadMangaDirectoriesByTID = directories
            let smartTIDs = Set(items.filter {
                $0.target.kind == .mangaThread && boardReaderSettings.isSmartComicModeEnabled(forumID: $0.forumID)
            }.compactMap(\.target.threadID))
            return directories.filter { smartTIDs.contains($0.key) }
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

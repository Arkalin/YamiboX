import Foundation
import Observation
import YamiboXCore

/// State and commands for the Reading settings page: per-board reader modes
/// and the novel offline cache switches.
@MainActor
@Observable
final class SettingsReadingViewModel: AppSettingsPersisting {
    var novelOfflineCache = NovelOfflineCacheSettings()
    var boardReader = BoardReaderSettings()

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity) {
        self.dependencies = dependencies
        self.activity = activity
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        novelOfflineCache = settings.novelOfflineCache
        boardReader = settings.boardReader
    }

    func restoreDefaultsAfterApplicationReset() {
        novelOfflineCache = NovelOfflineCacheSettings()
        boardReader = BoardReaderSettings()
    }

    // MARK: - Novel offline cache

    func updateNovelOfflineCacheRetainsInlineImages(_ retainsInlineImages: Bool) {
        var updated = novelOfflineCache
        updated.retainsInlineImages = retainsInlineImages
        updateNovelOfflineCache(updated)
    }

    func updateNovelOfflineCacheAutoRefreshEnabled(_ isAutoRefreshEnabled: Bool) {
        var updated = novelOfflineCache
        updated.isAutoRefreshEnabled = isAutoRefreshEnabled
        updateNovelOfflineCache(updated)
    }

    private func updateNovelOfflineCache(_ updated: NovelOfflineCacheSettings) {
        persistSettings(\.novelOfflineCache, to: updated) { $0.novelOfflineCache = updated }
    }

    // MARK: - Board reader

    /// Overwrites the board's entry with `mode`. `boardName` must be the
    /// entry's stored snapshot carried through unchanged — the central
    /// settings page cannot resolve real board names; only the board page
    /// ever writes or refreshes them.
    func setBoardReaderMode(_ mode: BoardReaderSettings.ReaderMode, forumID: String, boardName: String?) {
        let entry = BoardReaderSettings.Entry(mode: mode, boardName: boardName)
        var optimistic = boardReader
        optimistic.setEntry(entry, forumID: forumID)
        updateBoardReader(optimistic: optimistic) { settings in
            settings.boardReader.setEntry(entry, forumID: forumID)
        }
    }

    func resetBoardReader() {
        updateBoardReader(optimistic: .factoryDefault) { settings in
            settings.boardReader = .factoryDefault
        }
    }

    /// Entry-level persistence via the atomic `SettingsStore.update`: the
    /// mutation applies to *freshly loaded* settings inside the actor, so an
    /// entry another writer (e.g. a board page's sheet or name-snapshot
    /// refresh) persisted after this sheet's `load()` is never wiped by
    /// replaying this sheet's whole stale map. The published copy is
    /// optimistic display state; on success it resyncs to the persisted
    /// result (unless a newer local edit already superseded it). That
    /// success-resync step is why this stays bespoke instead of riding
    /// `persistSettingsAtomically`.
    private func updateBoardReader(
        optimistic updated: BoardReaderSettings,
        mutate: @escaping @Sendable (inout AppSettings) -> Void
    ) {
        let previous = boardReader
        boardReader = updated

        Task {
            do {
                let saved = try await dependencies.settingsStore.update(mutate)
                if boardReader == updated {
                    boardReader = saved.boardReader
                }
            } catch {
                if boardReader == updated {
                    boardReader = previous
                }
                errorMessage = error.localizedDescription
            }
        }
    }
}

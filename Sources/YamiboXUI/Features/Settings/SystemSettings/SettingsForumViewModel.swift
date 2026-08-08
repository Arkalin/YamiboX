import Foundation
import Observation
import YamiboXCore

/// State and commands for the Forum settings page's per-board reader modes.
@MainActor
@Observable
final class SettingsForumViewModel: AppSettingsPersisting {
    var boardReader = BoardReaderSettings()
    var enhancedCheckInEnabled = false

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity) {
        self.dependencies = dependencies
        self.activity = activity
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        boardReader = settings.boardReader
        enhancedCheckInEnabled = settings.system.enhancedCheckInEnabled
    }

    func restoreDefaultsAfterApplicationReset() {
        boardReader = BoardReaderSettings()
        enhancedCheckInEnabled = false
    }

    func updateEnhancedCheckInEnabled(_ value: Bool) {
        persistSettingsAtomically(\.enhancedCheckInEnabled, to: value) {
            $0.system.enhancedCheckInEnabled = value
        }
    }

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
    /// mutation applies to freshly loaded settings inside the store actor, so
    /// a board page's concurrent name-snapshot update is never overwritten by
    /// this page's stale snapshot.
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

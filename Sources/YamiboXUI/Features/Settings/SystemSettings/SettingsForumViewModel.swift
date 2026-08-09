import Foundation
import Observation
import YamiboXCore

/// State and commands for the Forum settings page's per-board reader modes.
@MainActor
@Observable
final class SettingsForumViewModel: AppSettingsPersisting {
    typealias AtomicSettingsUpdater = @Sendable (
        _ mutate: @Sendable (inout AppSettings) -> Void
    ) async throws -> AppSettings

    var boardReader = BoardReaderSettings()
    var enhancedCheckInEnabled = false
    var themePreset = ForumThemePreset.classic

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity
    private let updateSettings: AtomicSettingsUpdater

    init(
        dependencies: SettingsDependencies,
        activity: SystemSettingsActivity,
        updateSettings: AtomicSettingsUpdater? = nil
    ) {
        self.dependencies = dependencies
        self.activity = activity
        self.updateSettings = updateSettings ?? { mutate in
            try await dependencies.settingsStore.update(mutate)
        }
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        boardReader = settings.boardReader
        enhancedCheckInEnabled = settings.system.enhancedCheckInEnabled
        themePreset = settings.forumAppearance.themePreset
    }

    func restoreDefaultsAfterApplicationReset() {
        boardReader = BoardReaderSettings()
        enhancedCheckInEnabled = false
        themePreset = .classic
    }

    func updateEnhancedCheckInEnabled(_ value: Bool) {
        persistSettingsAtomically(\.enhancedCheckInEnabled, to: value) {
            $0.system.enhancedCheckInEnabled = value
        }
    }

    func updateThemePreset(_ value: ForumThemePreset) {
        guard themePreset != value else { return }
        let previous = themePreset
        themePreset = value

        Task {
            do {
                let saved = try await updateSettings { settings in
                    settings.forumAppearance.themePreset = value
                }
                if themePreset == value {
                    themePreset = saved.forumAppearance.themePreset
                }
            } catch {
                if themePreset == value {
                    themePreset = previous
                }
                errorMessage = error.localizedDescription
            }
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

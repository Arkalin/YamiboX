import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class SettingsForumViewModel: AppSettingsPersisting {
    var boardReader = BoardReaderSettings()
    var enhancedCheckInEnabled = false

    let dependencies: SettingsDependencies
    var settingsStore: SettingsStore { dependencies.settingsStore }
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
        persistSettings(\.enhancedCheckInEnabled, to: value) {
            $0.system.enhancedCheckInEnabled = value
        }
    }

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
                if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                    errorMessage = error.localizedDescription
                    errorDetails = LoadFailureDetails(error: error)
                }
            }
        }
    }
}

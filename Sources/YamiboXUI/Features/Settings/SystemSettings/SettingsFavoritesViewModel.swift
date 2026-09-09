import Foundation
import Observation
import YamiboXCore

/// State and commands for the Favorites settings page: library display
/// options, the custom background, and the sync behavior switches.
@MainActor
@Observable
final class SettingsFavoritesViewModel: AppSettingsPersisting {
    var favoriteBackground = FavoriteBackgroundSettings()
    var favoriteLayoutMode: FavoriteLibraryLayoutMode = .rowCard
    var favoriteGridCardScale = FavoriteLibrarySettings.defaultGridCardScale
    var favoriteSortOrder: LocalFavoriteLibrarySortOrder = .organization
    var favoriteSortDescending = false
    var favoriteShowsCategoryCounts = true
    var favoriteItemTapAction: FavoriteItemTapAction = .detail
    /// Android-style favorite sync behavior switches: each action has an
    /// "ask every time" toggle and, when asking is off, a silent default.
    /// The quick-action prompts' "remember" variants write the same fields,
    /// so this page is where a remembered choice can be revisited.
    var favoriteAddSyncPromptEnabled = true
    var favoriteAddSyncDefault = true
    var favoriteRemoveRemotePromptEnabled = true
    var favoriteRemoveRemoteDefault = false
    var favoriteSmartMangaBulkDeleteEnabled = true
    var favoriteSmartMangaBadgeEnabled = true

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity
    private let updateSettings: AtomicSettingsUpdater?

    init(
        dependencies: SettingsDependencies,
        activity: SystemSettingsActivity,
        updateSettings: AtomicSettingsUpdater? = nil
    ) {
        self.dependencies = dependencies
        self.activity = activity
        self.updateSettings = updateSettings
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        favoriteBackground = settings.favorites.background
        favoriteLayoutMode = settings.favorites.layoutMode
        favoriteGridCardScale = FavoriteLibrarySettings.clampGridCardScale(settings.favorites.gridCardScale)
        favoriteSortOrder = settings.favorites.sortOrder
        favoriteSortDescending = settings.favorites.sortDescending
        favoriteShowsCategoryCounts = settings.favorites.showsCategoryCounts
        favoriteItemTapAction = settings.favorites.itemTapAction
        favoriteAddSyncPromptEnabled = settings.favorites.addSyncPromptEnabled
        favoriteAddSyncDefault = settings.favorites.addSyncDefault
        favoriteRemoveRemotePromptEnabled = settings.favorites.removeRemotePromptEnabled
        favoriteRemoveRemoteDefault = settings.favorites.removeRemoteDefault
        favoriteSmartMangaBulkDeleteEnabled = settings.favorites.smartMangaBulkDeleteEnabled
        favoriteSmartMangaBadgeEnabled = settings.favorites.smartMangaBadgeEnabled
    }

    /// Application reset restores the background and tap preference here: the other display and
    /// sync-behavior fields are wiped in the *store* by `resetApplicationData`
    /// too, but the pre-split view model never mirrored them back to defaults
    /// in memory, and this refactor keeps that behavior unchanged.
    func restoreDefaultsAfterApplicationReset() {
        favoriteBackground = FavoriteBackgroundSettings()
        favoriteItemTapAction = .detail
    }

    // MARK: - Background image

    func loadFavoriteBackgroundImageData() async -> Data? {
        await dependencies.favoriteBackgroundImageStore.loadData(imageID: favoriteBackground.imageID)
    }

    func normalizedFavoriteBackgroundImageData(from data: Data) throws -> Data {
        try FavoriteBackgroundImageProcessor.normalizedJPEGData(from: data)
    }

    func applyFavoriteBackground(
        imageData: Data,
        draftSettings: FavoriteBackgroundSettings
    ) async -> Bool {
        let imageID = UUID().uuidString
        let updatedBackground = FavoriteBackgroundSettings(
            isEnabled: true,
            imageID: imageID,
            scale: draftSettings.scale,
            offsetX: draftSettings.offsetX,
            offsetY: draftSettings.offsetY,
            blurRadius: draftSettings.blurRadius
        )
        do {
            try await dependencies.favoriteBackgroundImageStore.save(imageData, imageID: imageID)

            try await dependencies.settingsStore.update {
                $0.favorites.background = updatedBackground
            }

            favoriteBackground = updatedBackground
            do {
                try await dependencies.favoriteBackgroundImageStore.prune(keeping: imageID)
            } catch {
                YamiboLog.persistence.warning("Failed to prune orphaned favorite background images after apply: \(error)")
            }
            return true
        } catch {
            do {
                try await dependencies.favoriteBackgroundImageStore.delete(imageID: imageID)
            } catch {
                YamiboLog.persistence.warning("Failed to roll back favorite background image after save failure: \(error)")
            }
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }

    func restoreDefaultFavoriteBackground() async -> Bool {
        do {
            try await dependencies.settingsStore.update {
                $0.favorites.background = FavoriteBackgroundSettings()
            }

            favoriteBackground = FavoriteBackgroundSettings()
            do {
                try await dependencies.favoriteBackgroundImageStore.deleteAll()
            } catch {
                YamiboLog.persistence.warning("Failed to delete favorite background images when restoring default: \(error)")
            }
            return true
        } catch {
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }

    // MARK: - Library display

    func updateFavoriteItemTapAction(_ value: FavoriteItemTapAction) {
        persistSettings(\.favoriteItemTapAction, to: value, updateSettings: updateSettings) {
            $0.favorites.itemTapAction = value
        }
    }

    func updateFavoriteLayoutMode(_ value: FavoriteLibraryLayoutMode) {
        persistSettings(\.favoriteLayoutMode, to: value, updateSettings: updateSettings) {
            $0.favorites.layoutMode = value
        }
    }

    func updateFavoriteSortOrder(_ value: LocalFavoriteLibrarySortOrder) {
        persistSettings(\.favoriteSortOrder, to: value, updateSettings: updateSettings) {
            $0.favorites.sortOrder = value
        }
    }

    func updateFavoriteSortDescending(_ value: Bool) {
        persistSettings(\.favoriteSortDescending, to: value, updateSettings: updateSettings) {
            $0.favorites.sortDescending = value
        }
    }

    func updateFavoriteShowsCategoryCounts(_ value: Bool) {
        persistSettings(\.favoriteShowsCategoryCounts, to: value, updateSettings: updateSettings) {
            $0.favorites.showsCategoryCounts = value
        }
    }

    /// Live slider tracking for the iPad grid card size: updates only the
    /// in-memory value so a drag does not enqueue one save per tick.
    /// `commitFavoriteGridCardScale()` persists once when the drag ends.
    func previewFavoriteGridCardScale(_ value: Double) {
        favoriteGridCardScale = FavoriteLibrarySettings.clampGridCardScale(value)
    }

    /// Persists the slider value on drag end. The optimistic value and the
    /// committed value coincide here (the drag already previewed it), so a
    /// failed save keeps showing the dragged value alongside the error
    /// message rather than yanking the knob back mid-look.
    func commitFavoriteGridCardScale() {
        let value = favoriteGridCardScale
        persistSettings(\.favoriteGridCardScale, to: value, updateSettings: updateSettings) {
            $0.favorites.gridCardScale = value
        }
    }

    // MARK: - Sync behavior

    func updateFavoriteAddSyncPromptEnabled(_ value: Bool) {
        persistSettings(\.favoriteAddSyncPromptEnabled, to: value, updateSettings: updateSettings) {
            $0.favorites.addSyncPromptEnabled = value
        }
    }

    func updateFavoriteAddSyncDefault(_ value: Bool) {
        persistSettings(\.favoriteAddSyncDefault, to: value, updateSettings: updateSettings) {
            $0.favorites.addSyncDefault = value
        }
    }

    func updateFavoriteRemoveRemotePromptEnabled(_ value: Bool) {
        persistSettings(\.favoriteRemoveRemotePromptEnabled, to: value, updateSettings: updateSettings) {
            $0.favorites.removeRemotePromptEnabled = value
        }
    }

    func updateFavoriteRemoveRemoteDefault(_ value: Bool) {
        persistSettings(\.favoriteRemoveRemoteDefault, to: value, updateSettings: updateSettings) {
            $0.favorites.removeRemoteDefault = value
        }
    }

    func updateFavoriteSmartMangaBulkDeleteEnabled(_ value: Bool) {
        persistSettings(\.favoriteSmartMangaBulkDeleteEnabled, to: value, updateSettings: updateSettings) {
            $0.favorites.smartMangaBulkDeleteEnabled = value
        }
    }

    func updateFavoriteSmartMangaBadgeEnabled(_ value: Bool) {
        persistSettings(\.favoriteSmartMangaBadgeEnabled, to: value, updateSettings: updateSettings) {
            $0.favorites.smartMangaBadgeEnabled = value
        }
    }
}

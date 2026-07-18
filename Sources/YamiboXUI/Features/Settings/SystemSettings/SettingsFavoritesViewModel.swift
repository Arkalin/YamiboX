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
    var favoriteSortOrder: LocalFavoriteLibrarySortOrder = .organization
    var favoriteSortDescending = false
    var favoriteShowsCategoryCounts = true
    /// Android-style favorite sync behavior switches: each action has an
    /// "ask every time" toggle and, when asking is off, a silent default.
    /// The quick-action prompts' "remember" variants write the same fields,
    /// so this page is where a remembered choice can be revisited.
    var favoriteAddSyncPromptEnabled = true
    var favoriteAddSyncDefault = true
    var favoriteRemoveRemotePromptEnabled = true
    var favoriteRemoveRemoteDefault = false
    var favoriteSmartMangaBulkDeleteEnabled = true

    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies, activity: SystemSettingsActivity) {
        self.dependencies = dependencies
        self.activity = activity
    }

    func applyLoadedSettings(_ settings: AppSettings) {
        favoriteBackground = settings.favorites.background
        favoriteLayoutMode = settings.favorites.layoutMode
        favoriteSortOrder = settings.favorites.sortOrder
        favoriteSortDescending = settings.favorites.sortDescending
        favoriteShowsCategoryCounts = settings.favorites.showsCategoryCounts
        favoriteAddSyncPromptEnabled = settings.favorites.addSyncPromptEnabled
        favoriteAddSyncDefault = settings.favorites.addSyncDefault
        favoriteRemoveRemotePromptEnabled = settings.favorites.removeRemotePromptEnabled
        favoriteRemoveRemoteDefault = settings.favorites.removeRemoteDefault
        favoriteSmartMangaBulkDeleteEnabled = settings.favorites.smartMangaBulkDeleteEnabled
    }

    /// Application reset restores only the background here: the display and
    /// sync-behavior fields are wiped in the *store* by `resetApplicationData`
    /// too, but the pre-split view model never mirrored them back to defaults
    /// in memory, and this refactor keeps that behavior unchanged.
    func restoreDefaultsAfterApplicationReset() {
        favoriteBackground = FavoriteBackgroundSettings()
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
        var updatedBackground = FavoriteBackgroundSettings(
            isEnabled: true,
            imageID: imageID,
            scale: draftSettings.scale,
            offsetX: draftSettings.offsetX,
            offsetY: draftSettings.offsetY,
            blurRadius: draftSettings.blurRadius
        )
        updatedBackground.isEnabled = true

        do {
            try await dependencies.favoriteBackgroundImageStore.save(imageData, imageID: imageID)

            var settings = await dependencies.settingsStore.load()
            settings.favorites.background = updatedBackground
            try await dependencies.settingsStore.save(settings)

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
            errorMessage = error.localizedDescription
            return false
        }
    }

    func restoreDefaultFavoriteBackground() async -> Bool {
        do {
            var settings = await dependencies.settingsStore.load()
            settings.favorites.background = FavoriteBackgroundSettings()
            try await dependencies.settingsStore.save(settings)

            favoriteBackground = FavoriteBackgroundSettings()
            do {
                try await dependencies.favoriteBackgroundImageStore.deleteAll()
            } catch {
                YamiboLog.persistence.warning("Failed to delete favorite background images when restoring default: \(error)")
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Library display

    func updateFavoriteLayoutMode(_ value: FavoriteLibraryLayoutMode) {
        persistSettings(\.favoriteLayoutMode, to: value) { [self] settings in
            applyFavoriteLibraryDisplaySettings(to: &settings)
        }
    }

    func updateFavoriteSortOrder(_ value: LocalFavoriteLibrarySortOrder) {
        persistSettings(\.favoriteSortOrder, to: value) { [self] settings in
            applyFavoriteLibraryDisplaySettings(to: &settings)
        }
    }

    func updateFavoriteSortDescending(_ value: Bool) {
        persistSettings(\.favoriteSortDescending, to: value) { [self] settings in
            applyFavoriteLibraryDisplaySettings(to: &settings)
        }
    }

    func updateFavoriteShowsCategoryCounts(_ value: Bool) {
        persistSettings(\.favoriteShowsCategoryCounts, to: value) { [self] settings in
            applyFavoriteLibraryDisplaySettings(to: &settings)
        }
    }

    /// The display quad persists as a unit (all four current values, read at
    /// persist time) so rapid edits across different display fields cannot
    /// resurrect a stale sibling value from an earlier in-flight save.
    private func applyFavoriteLibraryDisplaySettings(to settings: inout AppSettings) {
        settings.favorites.layoutMode = favoriteLayoutMode
        settings.favorites.sortOrder = favoriteSortOrder
        settings.favorites.sortDescending = favoriteSortDescending
        settings.favorites.showsCategoryCounts = favoriteShowsCategoryCounts
    }

    // MARK: - Sync behavior

    // These persist atomically (not load/save) because other screens' prompt
    // "remember" actions write the same fields concurrently; see
    // `persistSettingsAtomically`.

    func updateFavoriteAddSyncPromptEnabled(_ value: Bool) {
        persistSettingsAtomically(\.favoriteAddSyncPromptEnabled, to: value) {
            $0.favorites.addSyncPromptEnabled = value
        }
    }

    func updateFavoriteAddSyncDefault(_ value: Bool) {
        persistSettingsAtomically(\.favoriteAddSyncDefault, to: value) {
            $0.favorites.addSyncDefault = value
        }
    }

    func updateFavoriteRemoveRemotePromptEnabled(_ value: Bool) {
        persistSettingsAtomically(\.favoriteRemoveRemotePromptEnabled, to: value) {
            $0.favorites.removeRemotePromptEnabled = value
        }
    }

    func updateFavoriteRemoveRemoteDefault(_ value: Bool) {
        persistSettingsAtomically(\.favoriteRemoveRemoteDefault, to: value) {
            $0.favorites.removeRemoteDefault = value
        }
    }

    func updateFavoriteSmartMangaBulkDeleteEnabled(_ value: Bool) {
        persistSettingsAtomically(\.favoriteSmartMangaBulkDeleteEnabled, to: value) {
            $0.favorites.smartMangaBulkDeleteEnabled = value
        }
    }
}

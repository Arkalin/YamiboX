import Foundation
import Observation
import YamiboXCore

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
    var favoriteAddSyncPromptEnabled = true
    var favoriteAddSyncDefault = true
    var favoriteRemoveRemotePromptEnabled = true
    var favoriteRemoveRemoteDefault = false
    var favoriteSmartMangaBulkDeleteEnabled = true
    var favoriteSmartMangaBadgeEnabled = true

    let dependencies: SettingsDependencies
    var settingsStore: SettingsStore { dependencies.settingsStore }
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

    func restoreDefaultsAfterApplicationReset() {
        applyLoadedSettings(AppSettings())
    }

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

    func previewFavoriteGridCardScale(_ value: Double) {
        favoriteGridCardScale = FavoriteLibrarySettings.clampGridCardScale(value)
    }

    func commitFavoriteGridCardScale() {
        let value = favoriteGridCardScale
        persistSettings(\.favoriteGridCardScale, to: value, updateSettings: updateSettings) {
            $0.favorites.gridCardScale = value
        }
    }


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

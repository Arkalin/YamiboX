import Foundation
import Observation
import YamiboXCore

/// Composition root for the system settings feature.
///
/// Formerly a monolith carrying every page's state; now it only builds the
/// per-page view models around the two genuinely cross-page pieces
/// (``SystemSettingsActivity`` and ``SettingsStorageUsage``), performs the
/// single up-front load the root screen has always done, and keeps the one
/// bit of state only the root screen shows (`isLoggedIn`).
@MainActor
@Observable
final class SystemSettingsViewModel {
    let dependencies: SettingsDependencies

    let general: SettingsGeneralViewModel
    let favorites: SettingsFavoritesViewModel
    let reading: SettingsReadingViewModel
    let peripherals: SettingsPeripheralsViewModel
    let storage: SettingsStorageViewModel
    let offlineCacheManagement: OfflineCacheManagementViewModel
    let mangaDirectoryManagement: MangaDirectoryManagementViewModel

    private(set) var isLoggedIn = false

    private let activity: SystemSettingsActivity
    private let storageUsage: SettingsStorageUsage

    init(dependencies: SettingsDependencies) {
        let activity = SystemSettingsActivity()
        let storageUsage = SettingsStorageUsage(dependencies: dependencies)
        let general = SettingsGeneralViewModel(dependencies: dependencies, activity: activity)
        let favorites = SettingsFavoritesViewModel(dependencies: dependencies, activity: activity)
        let reading = SettingsReadingViewModel(dependencies: dependencies, activity: activity)
        let peripherals = SettingsPeripheralsViewModel(dependencies: dependencies, activity: activity)
        let storage = SettingsStorageViewModel(
            dependencies: dependencies,
            activity: activity,
            storageUsage: storageUsage
        )
        let offlineCacheManagement = OfflineCacheManagementViewModel(
            dependencies: dependencies,
            activity: activity,
            storageUsage: storageUsage
        )
        let mangaDirectoryManagement = MangaDirectoryManagementViewModel(
            dependencies: dependencies,
            activity: activity,
            storageUsage: storageUsage
        )

        // Application reset (triggered on the storage page) wipes every
        // page's persisted state; fan the in-memory reset out to the sibling
        // pages here, where all of them are known. Capturing the locals (not
        // `self`) keeps the storage model free of a reference cycle back
        // through this root.
        storage.onApplicationDataReset = {
            general.restoreDefaultsAfterApplicationReset()
            favorites.restoreDefaultsAfterApplicationReset()
            reading.restoreDefaultsAfterApplicationReset()
            peripherals.restoreDefaultsAfterApplicationReset()
            offlineCacheManagement.restoreDefaultsAfterApplicationReset()
            mangaDirectoryManagement.restoreDefaultsAfterApplicationReset()
        }

        self.dependencies = dependencies
        self.activity = activity
        self.storageUsage = storageUsage
        self.general = general
        self.favorites = favorites
        self.reading = reading
        self.peripherals = peripherals
        self.storage = storage
        self.offlineCacheManagement = offlineCacheManagement
        self.mangaDirectoryManagement = mangaDirectoryManagement
    }

    /// The root screen gates navigation into *any* category on this, so an
    /// action still running on one page can never be joined by another
    /// concurrent action (or sign-out) started elsewhere.
    var isBusy: Bool {
        activity.isBusy
    }

    /// Root-screen error surface; the root also *sets* this (sign-out
    /// failures land here), hence the setter passthrough.
    var errorMessage: String? {
        get { activity.errorMessage }
        set { activity.errorMessage = newValue }
    }

    /// One settings-store read populates every page, exactly as the
    /// pre-split monolith loaded — pages render instantly when pushed
    /// instead of each doing its own first load.
    func load() async {
        activity.activeAction = .loading
        defer { activity.activeAction = nil }

        let settings = await dependencies.settingsStore.load()
        general.applyLoadedSettings(settings)
        favorites.applyLoadedSettings(settings)
        reading.applyLoadedSettings(settings)
        peripherals.applyLoadedSettings(settings)
        let session = await dependencies.sessionStore.load()
        isLoggedIn = session.isLoggedIn && SessionState.hasAuthenticationCookie(session.cookie)
        await storageUsage.refresh()
    }
}

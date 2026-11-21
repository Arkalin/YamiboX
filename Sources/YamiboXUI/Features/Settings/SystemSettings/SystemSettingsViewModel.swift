import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class SystemSettingsViewModel {
    let dependencies: SettingsDependencies

    let general: SettingsGeneralViewModel
    let bookshelf: SettingsBookshelfViewModel
    let forum: SettingsForumViewModel
    let favorites: SettingsFavoritesViewModel
    let reading: SettingsReadingViewModel
    let peripherals: SettingsPeripheralsViewModel
    let storage: SettingsStorageViewModel
    let downloadManagement: DownloadManagementViewModel
    let mangaDirectoryManagement: MangaDirectoryManagementViewModel

    private(set) var isLoggedIn = false

    private let activity: SystemSettingsActivity

    init(dependencies: SettingsDependencies) {
        let activity = SystemSettingsActivity()
        let storageUsage = SettingsStorageUsage(dependencies: dependencies)
        let general = SettingsGeneralViewModel(dependencies: dependencies, activity: activity)
        let bookshelf = SettingsBookshelfViewModel(dependencies: dependencies, activity: activity)
        let forum = SettingsForumViewModel(dependencies: dependencies, activity: activity)
        let favorites = SettingsFavoritesViewModel(dependencies: dependencies, activity: activity)
        let reading = SettingsReadingViewModel(dependencies: dependencies, activity: activity)
        let peripherals = SettingsPeripheralsViewModel(settingsStore: dependencies.settingsStore, activity: activity)
        let storage = SettingsStorageViewModel(
            dependencies: dependencies,
            activity: activity,
            storageUsage: storageUsage
        )
        let downloadManagement = DownloadManagementViewModel(
            downloadStore: dependencies.downloadStore,
            sessionStore: dependencies.sessionStore,
            onDeletion: { await storageUsage.refresh() }
        )
        let mangaDirectoryManagement = MangaDirectoryManagementViewModel(
            dependencies: dependencies,
            activity: activity,
            storageUsage: storageUsage
        )

        storage.onApplicationDataReset = {
            general.restoreDefaultsAfterApplicationReset()
            bookshelf.restoreDefaultsAfterApplicationReset()
            forum.restoreDefaultsAfterApplicationReset()
            favorites.restoreDefaultsAfterApplicationReset()
            reading.restoreDefaultsAfterApplicationReset()
            peripherals.restoreDefaultsAfterApplicationReset()
            downloadManagement.restoreDefaultsAfterApplicationReset()
            mangaDirectoryManagement.restoreDefaultsAfterApplicationReset()
        }

        self.dependencies = dependencies
        self.activity = activity
        self.general = general
        self.bookshelf = bookshelf
        self.forum = forum
        self.favorites = favorites
        self.reading = reading
        self.peripherals = peripherals
        self.storage = storage
        self.downloadManagement = downloadManagement
        self.mangaDirectoryManagement = mangaDirectoryManagement
    }

    var isBusy: Bool {
        activity.isBusy || downloadManagement.activeAction == .clearingDownload
    }

    var errorIdentity: UUID { activity.errorIdentity }

    var errorMessage: String? {
        get { activity.errorMessage }
        set { activity.errorMessage = newValue }
    }

    var errorDetails: LoadFailureDetails? {
        get { activity.errorDetails }
        set { activity.errorDetails = newValue }
    }

    func load() async {
        activity.activeAction = .loading
        defer { activity.activeAction = nil }

        let settings = await dependencies.settingsStore.load()
        general.applyLoadedSettings(settings)
        bookshelf.applyLoadedSettings(settings)
        forum.applyLoadedSettings(settings)
        favorites.applyLoadedSettings(settings)
        reading.applyLoadedSettings(settings)
        peripherals.applyLoadedSettings(settings)
        await refreshSessionState()
    }

    func refreshSessionState() async {
        let session = await dependencies.sessionStore.load()
        isLoggedIn = session.isLoggedIn && session.hasValidAuthenticationCookie
    }
}

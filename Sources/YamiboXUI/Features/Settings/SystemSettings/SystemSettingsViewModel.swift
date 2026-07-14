import SwiftUI
import YamiboXCore

@MainActor
final class SystemSettingsViewModel: ObservableObject {
    @Published var homePage: AppHomePage = .forum
    @Published var favoriteBackground = FavoriteBackgroundSettings()
    @Published var favoriteLayoutMode: FavoriteLibraryLayoutMode = .rowCard
    @Published var favoriteSortOrder: LocalFavoriteLibrarySortOrder = .organization
    @Published var favoriteSortDescending = false
    @Published var favoriteShowsCategoryCounts = true
    /// Android-style favorite sync behavior switches: each action has an
    /// "ask every time" toggle and, when asking is off, a silent default.
    /// The quick-action prompts' "remember" variants write the same fields,
    /// so this page is where a remembered choice can be revisited.
    @Published var favoriteAddSyncPromptEnabled = true
    @Published var favoriteAddSyncDefault = true
    @Published var favoriteRemoveRemotePromptEnabled = true
    @Published var favoriteRemoveRemoteDefault = false
    @Published var favoriteSmartMangaBulkDeleteEnabled = true
    @Published var novelOfflineCache = NovelOfflineCacheSettings()
    @Published var applePencilPageTurn = ApplePencilPageTurnSettings()
    @Published var gamepad = GamepadSettings()
    @Published var keyboard = KeyboardSettings()
    @Published var boardReader = BoardReaderSettings()
    @Published private(set) var isLoggedIn = false
    @Published private(set) var webReaderCacheBytes = 0
    @Published private(set) var contentCoverCacheBytes = 0
    @Published private(set) var mangaDirectoryCacheBytes = 0
    @Published private(set) var offlineCacheBytes = 0
    @Published var offlineCacheManagementRows: [OfflineCacheManagementRow] = []
    @Published var selectedOfflineCacheGroupIDs: Set<OfflineCacheGroupID> = []
    @Published var isOfflineCacheManagementSelectionMode = false
    @Published var pendingOfflineCacheManagementConfirmation: OfflineCacheManagementConfirmation?
    @Published var mangaDirectoryManagementRows: [MangaDirectoryManagementRow] = []
    @Published var selectedMangaDirectoryIDs: Set<String> = []
    @Published var isMangaDirectoryManagementSelectionMode = false
    @Published var pendingMangaDirectoryManagementConfirmation: MangaDirectoryManagementConfirmation?
    @Published var activeAction: SystemSettingsAction?
    @Published var errorMessage: String?

    let dependencies: SettingsDependencies

    init(dependencies: SettingsDependencies) {
        self.dependencies = dependencies
    }

    var isBusy: Bool {
        activeAction != nil
    }

    var webReaderCacheLabel: String {
        cacheLabel(for: webReaderCacheBytes)
    }

    var contentCoverCacheLabel: String {
        cacheLabel(for: contentCoverCacheBytes)
    }

    var mangaDirectoryCacheLabel: String {
        cacheLabel(for: mangaDirectoryCacheBytes)
    }

    var offlineCacheLabel: String {
        cacheLabel(for: offlineCacheBytes)
    }

    var offlineCacheManagementIsEmpty: Bool {
        offlineCacheManagementRows.isEmpty
    }

    var selectedOfflineCacheGroupCount: Int {
        selectedOfflineCacheGroupIDs.count
    }

    var offlineCacheManagementSelectionActionState: OfflineCacheManagementSelectionActionState {
        OfflineCacheManagementSelectionActionState(
            selectedGroupCount: selectedOfflineCacheGroupIDs.count,
            canDelete: !selectedOfflineCacheGroupIDs.isEmpty
                && activeAction != .clearingOfflineCache
        )
    }

    var mangaDirectoryManagementIsEmpty: Bool {
        mangaDirectoryManagementRows.isEmpty
    }

    var selectedMangaDirectoryCount: Int {
        selectedMangaDirectoryIDs.count
    }

    var mangaDirectoryManagementCanDeleteSelected: Bool {
        !selectedMangaDirectoryIDs.isEmpty && activeAction != .clearingMangaDirectory
    }

    // MARK: - Loading

    func load() async {
        activeAction = .loading
        defer { activeAction = nil }

        let settings = await dependencies.settingsStore.load()
        homePage = settings.system.homePage
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
        novelOfflineCache = settings.novelOfflineCache
        applePencilPageTurn = settings.system.applePencilPageTurn
        gamepad = settings.system.gamepad
        keyboard = settings.system.keyboard
        boardReader = settings.boardReader
        let session = await dependencies.sessionStore.load()
        isLoggedIn = session.isLoggedIn && SessionState.hasAuthenticationCookie(session.cookie)
        await refreshStorageUsage()
    }

    // MARK: - General

    func updateHomePage(_ value: AppHomePage) {
        let previous = homePage
        homePage = value

        Task {
            var settings = await dependencies.settingsStore.load()
            settings.system.homePage = value

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    homePage = previous
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Favorites appearance and display

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

    func updateFavoriteLayoutMode(_ value: FavoriteLibraryLayoutMode) {
        let previous = favoriteLayoutMode
        favoriteLayoutMode = value

        Task {
            var settings = await dependencies.settingsStore.load()
            applyFavoriteLibraryDisplaySettings(to: &settings)

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    if favoriteLayoutMode == value {
                        favoriteLayoutMode = previous
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateFavoriteSortOrder(_ value: LocalFavoriteLibrarySortOrder) {
        let previous = favoriteSortOrder
        favoriteSortOrder = value

        Task {
            var settings = await dependencies.settingsStore.load()
            applyFavoriteLibraryDisplaySettings(to: &settings)

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    if favoriteSortOrder == value {
                        favoriteSortOrder = previous
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateFavoriteSortDescending(_ value: Bool) {
        let previous = favoriteSortDescending
        favoriteSortDescending = value

        Task {
            var settings = await dependencies.settingsStore.load()
            applyFavoriteLibraryDisplaySettings(to: &settings)

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    if favoriteSortDescending == value {
                        favoriteSortDescending = previous
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateFavoriteShowsCategoryCounts(_ value: Bool) {
        let previous = favoriteShowsCategoryCounts
        favoriteShowsCategoryCounts = value

        Task {
            var settings = await dependencies.settingsStore.load()
            applyFavoriteLibraryDisplaySettings(to: &settings)

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    if favoriteShowsCategoryCounts == value {
                        favoriteShowsCategoryCounts = previous
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func applyFavoriteLibraryDisplaySettings(to settings: inout AppSettings) {
        settings.favorites.layoutMode = favoriteLayoutMode
        settings.favorites.sortOrder = favoriteSortOrder
        settings.favorites.sortDescending = favoriteSortDescending
        settings.favorites.showsCategoryCounts = favoriteShowsCategoryCounts
    }

    // MARK: - Peripherals (Apple Pencil / gamepad / keyboard)

    func updateApplePencilPageTurnEnabled(_ isEnabled: Bool) {
        var updated = applePencilPageTurn
        updated.isEnabled = isEnabled
        updateApplePencilPageTurn(updated)
    }

    func updateApplePencilPageTurnBehavior(_ behavior: ApplePencilPageTurnBehavior) {
        var updated = applePencilPageTurn
        updated.behavior = behavior
        updateApplePencilPageTurn(updated)
    }

    func updateGamepadEnabled(_ isEnabled: Bool) {
        var updated = gamepad
        updated.isEnabled = isEnabled
        updateGamepad(updated)
    }

    func bindGamepadAction(_ action: ReaderControlAction, toElementAlias alias: String) {
        var updated = gamepad
        updated.bind(action, toElementAlias: alias)
        updateGamepad(updated)
    }

    func clearGamepadBinding(for action: ReaderControlAction) {
        var updated = gamepad
        updated.clearBinding(for: action)
        updateGamepad(updated)
    }

    func restoreGamepadDefaultBindings() {
        var updated = gamepad
        updated.restoreDefaultBindings()
        updateGamepad(updated)
    }

    func updateKeyboardEnabled(_ isEnabled: Bool) {
        var updated = keyboard
        updated.isEnabled = isEnabled
        updateKeyboard(updated)
    }

    func bindKeyboardAction(_ action: ReaderControlAction, toKeyCode code: Int) {
        var updated = keyboard
        updated.bind(action, toKeyCode: code)
        updateKeyboard(updated)
    }

    func clearKeyboardBinding(for action: ReaderControlAction) {
        var updated = keyboard
        updated.clearBinding(for: action)
        updateKeyboard(updated)
    }

    func restoreKeyboardDefaultBindings() {
        var updated = keyboard
        updated.restoreDefaultBindings()
        updateKeyboard(updated)
    }

    // MARK: - Favorite sync behavior

    func updateFavoriteAddSyncPromptEnabled(_ value: Bool) {
        let previous = favoriteAddSyncPromptEnabled
        favoriteAddSyncPromptEnabled = value
        persistFavoriteSyncBehavior { settings in
            settings.favorites.addSyncPromptEnabled = value
        } revert: { [weak self] in
            self?.favoriteAddSyncPromptEnabled = previous
        }
    }

    func updateFavoriteAddSyncDefault(_ value: Bool) {
        let previous = favoriteAddSyncDefault
        favoriteAddSyncDefault = value
        persistFavoriteSyncBehavior { settings in
            settings.favorites.addSyncDefault = value
        } revert: { [weak self] in
            self?.favoriteAddSyncDefault = previous
        }
    }

    func updateFavoriteRemoveRemotePromptEnabled(_ value: Bool) {
        let previous = favoriteRemoveRemotePromptEnabled
        favoriteRemoveRemotePromptEnabled = value
        persistFavoriteSyncBehavior { settings in
            settings.favorites.removeRemotePromptEnabled = value
        } revert: { [weak self] in
            self?.favoriteRemoveRemotePromptEnabled = previous
        }
    }

    func updateFavoriteRemoveRemoteDefault(_ value: Bool) {
        let previous = favoriteRemoveRemoteDefault
        favoriteRemoveRemoteDefault = value
        persistFavoriteSyncBehavior { settings in
            settings.favorites.removeRemoteDefault = value
        } revert: { [weak self] in
            self?.favoriteRemoveRemoteDefault = previous
        }
    }

    func updateFavoriteSmartMangaBulkDeleteEnabled(_ value: Bool) {
        let previous = favoriteSmartMangaBulkDeleteEnabled
        favoriteSmartMangaBulkDeleteEnabled = value
        persistFavoriteSyncBehavior { settings in
            settings.favorites.smartMangaBulkDeleteEnabled = value
        } revert: { [weak self] in
            self?.favoriteSmartMangaBulkDeleteEnabled = previous
        }
    }

    private func persistFavoriteSyncBehavior(
        _ mutate: @escaping @Sendable (inout AppSettings) -> Void,
        revert: @escaping @MainActor () -> Void
    ) {
        Task {
            do {
                _ = try await dependencies.settingsStore.update(mutate)
            } catch {
                await MainActor.run {
                    revert()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Reading (novel offline cache / board reader)

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

    /// Clears every `DiskCacheStore`-backed render/HTML cache: novel and manga
    /// reader page projections plus the forum home/board/thread-page cache.
    /// These three share the same underlying engine and are all equally
    /// re-fetchable, so a single button covers all of them.
    // MARK: - Storage and cache actions

    func clearWebReaderCache() async -> Bool {
        activeAction = .clearingWebReaderCache
        defer { activeAction = nil }

        do {
            try await dependencies.novelReaderCacheStore.clearAll()
            try await dependencies.mangaReaderProjectionStore.clearAll()
            try await dependencies.forumCacheStore.clearAll()
            await refreshStorageUsage()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearContentCoverCache() async -> Bool {
        activeAction = .clearingContentCoverCache
        defer { activeAction = nil }

        do {
            try await dependencies.contentCoverStore.clearAll()
            await refreshStorageUsage()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearImageCache() async -> Bool {
        activeAction = .clearingImageCache
        defer { activeAction = nil }

        await dependencies.clearOrdinaryImageCache()
        await refreshStorageUsage()
        return true
    }

    /// Clears the system HTTP cache plus two small stores with no other
    /// bulk-clear entry point: the per-account check-in date cache and the
    /// favorites-update tracking state (tracked targets, detected events, run
    /// history, fid/category filters).
    func clearOtherCaches() async -> Bool {
        activeAction = .clearingOtherCaches
        defer { activeAction = nil }

        URLCache.shared.removeAllCachedResponses()
        await dependencies.checkInStore.clearAll()
        do {
            try await dependencies.favoriteUpdateStore.clearAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func resetApplication() async -> Bool {
        activeAction = .resettingApplication
        defer { activeAction = nil }

        do {
            try await dependencies.resetApplicationData()
            homePage = .forum
            favoriteBackground = .init()
            novelOfflineCache = .init()
            applePencilPageTurn = .init()
            gamepad = .init()
            keyboard = .init()
            boardReader = .init()
            webReaderCacheBytes = 0
            contentCoverCacheBytes = 0
            mangaDirectoryCacheBytes = 0
            offlineCacheBytes = 0
            offlineCacheManagementRows = []
            selectedOfflineCacheGroupIDs = []
            isOfflineCacheManagementSelectionMode = false
            pendingOfflineCacheManagementConfirmation = nil
            mangaDirectoryManagementRows = []
            selectedMangaDirectoryIDs = []
            isMangaDirectoryManagementSelectionMode = false
            pendingMangaDirectoryManagementConfirmation = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshStorageUsage() async {
        let novelBytes = await dependencies.novelReaderCacheStore.totalDiskUsageBytes()
        let mangaProjectionBytes = await dependencies.mangaReaderProjectionStore.totalDiskUsageBytes()
        let forumBytes = await dependencies.forumCacheStore.totalDiskUsageBytes()
        webReaderCacheBytes = novelBytes + mangaProjectionBytes + forumBytes
        contentCoverCacheBytes = await dependencies.contentCoverStore.totalDiskUsageBytes()
        mangaDirectoryCacheBytes = await dependencies.mangaDirectoryStore.totalDiskUsageBytes()
        offlineCacheBytes = await dependencies.offlineCacheStore.totalDiskUsageBytes()
    }

    // MARK: - Shared helpers

    private func cacheLabel(for bytes: Int) -> String {
        let megabytes = Double(max(0, bytes)) / 1_048_576
        return String(format: "%.2f MB", megabytes)
    }

    private func updateApplePencilPageTurn(_ updated: ApplePencilPageTurnSettings) {
        let previous = applePencilPageTurn
        applePencilPageTurn = updated

        Task {
            var settings = await dependencies.settingsStore.load()
            settings.system.applePencilPageTurn = updated

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    if applePencilPageTurn == updated {
                        applePencilPageTurn = previous
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updateGamepad(_ updated: GamepadSettings) {
        let previous = gamepad
        gamepad = updated

        Task {
            var settings = await dependencies.settingsStore.load()
            settings.system.gamepad = updated

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    if gamepad == updated {
                        gamepad = previous
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updateKeyboard(_ updated: KeyboardSettings) {
        let previous = keyboard
        keyboard = updated

        Task {
            var settings = await dependencies.settingsStore.load()
            settings.system.keyboard = updated

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    if keyboard == updated {
                        keyboard = previous
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Entry-level persistence via the atomic `SettingsStore.update`: the
    /// mutation applies to *freshly loaded* settings inside the actor, so an
    /// entry another writer (e.g. a board page's sheet or name-snapshot
    /// refresh) persisted after this sheet's `load()` is never wiped by
    /// replaying this sheet's whole stale map. The `@Published` copy is
    /// optimistic display state; on success it resyncs to the persisted
    /// result (unless a newer local edit already superseded it).
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

    private func updateNovelOfflineCache(_ updated: NovelOfflineCacheSettings) {
        let previous = novelOfflineCache
        novelOfflineCache = updated

        Task {
            var settings = await dependencies.settingsStore.load()
            settings.novelOfflineCache = updated

            do {
                try await dependencies.settingsStore.save(settings)
            } catch {
                await MainActor.run {
                    if novelOfflineCache == updated {
                        novelOfflineCache = previous
                    }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

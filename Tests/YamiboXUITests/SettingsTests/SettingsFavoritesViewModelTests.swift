import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

// The favorites page's slice (display options, background, sync behavior) of
// the former SystemSettingsViewModelTests.
@MainActor
final class SettingsFavoritesViewModelTests: XCTestCase {
    func testItemTapActionLoadsPersistsAndResets() async throws {
        let fixture = try makeSystemSettingsFixture()
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.load()
        XCTAssertEqual(settings.favorites.favoriteItemTapAction, .detail)

        for action in [FavoriteItemTapAction.read, .detail] {
            settings.favorites.updateFavoriteItemTapAction(action)
            XCTAssertEqual(settings.favorites.favoriteItemTapAction, action)
            try await waitForSettings { await fixture.settingsStore.load().favorites.itemTapAction == action }
            let reloaded = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
            await reloaded.load()
            XCTAssertEqual(reloaded.favorites.favoriteItemTapAction, action)
        }

        settings.favorites.applyLoadedSettings(AppSettings(favorites: .init(itemTapAction: .read)))
        settings.favorites.restoreDefaultsAfterApplicationReset()
        XCTAssertEqual(settings.favorites.favoriteItemTapAction, .detail)
    }

    func testItemTapActionSaveFailureRollsBackAndReportsError() async throws {
        let fixture = try makeSystemSettingsFixture()
        let viewModel = SettingsFavoritesViewModel(
            dependencies: fixture.appContext.settingsDependencies,
            activity: SystemSettingsActivity(),
            updateSettings: { _ in throw YamiboError.underlying("Tap preference save failed") }
        )
        viewModel.updateFavoriteItemTapAction(.read)
        XCTAssertEqual(viewModel.favoriteItemTapAction, .read)
        try await waitForSettings { viewModel.errorMessage != nil }
        XCTAssertEqual(viewModel.favoriteItemTapAction, .detail)
        XCTAssertNotNil(viewModel.errorDetails)
        let saved = await fixture.settingsStore.load()
        XCTAssertEqual(saved.favorites.itemTapAction, .detail)
    }

    func testLoadReadsFavoriteBackgroundSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        let savedSettings = FavoriteBackgroundSettings(
            isEnabled: true,
            imageID: "background",
            scale: 1.7,
            offsetX: 0.2,
            offsetY: -0.3,
            blurRadius: 11
        )
        try await fixture.settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(background: savedSettings)))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.load()

        XCTAssertEqual(settings.favorites.favoriteBackground, savedSettings)
    }

    func testFavoriteLibraryDisplaySettingsLoadAndPersist() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(
            layoutMode: .staggered,
            gridCardScale: 1.3,
            sortOrder: .displayTitle,
            sortDescending: true,
            showsCategoryCounts: false
        )))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.favorites
        await settings.load()

        XCTAssertEqual(viewModel.favoriteLayoutMode, .staggered)
        XCTAssertEqual(viewModel.favoriteGridCardScale, 1.3)
        XCTAssertEqual(viewModel.favoriteSortOrder, .displayTitle)
        XCTAssertTrue(viewModel.favoriteSortDescending)
        XCTAssertFalse(viewModel.favoriteShowsCategoryCounts)

        viewModel.updateFavoriteLayoutMode(.fixedGrid)
        viewModel.updateFavoriteSortOrder(.lastReadAt)
        viewModel.updateFavoriteSortDescending(false)
        viewModel.updateFavoriteShowsCategoryCounts(true)

        try await waitForSettings {
            let loaded = await fixture.settingsStore.load()
            return loaded.favorites.layoutMode == .fixedGrid
                && loaded.favorites.sortOrder == .lastReadAt
                && !loaded.favorites.sortDescending
                && loaded.favorites.showsCategoryCounts
        }
        XCTAssertEqual(viewModel.favoriteLayoutMode, .fixedGrid)
        XCTAssertEqual(viewModel.favoriteSortOrder, .lastReadAt)
        XCTAssertFalse(viewModel.favoriteSortDescending)
        XCTAssertTrue(viewModel.favoriteShowsCategoryCounts)
    }

    /// The grid card size slider previews drag ticks in memory only; the
    /// single commit on drag end persists the previewed value (clamped) as
    /// part of the display unit.
    func testFavoriteGridCardScalePreviewsInMemoryAndCommitsOnce() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(
            gridCardScale: 1.3
        )))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.favorites
        await settings.load()
        XCTAssertEqual(viewModel.favoriteGridCardScale, 1.3)

        viewModel.previewFavoriteGridCardScale(1.8)
        XCTAssertEqual(viewModel.favoriteGridCardScale, 1.8)
        let storedDuringDrag = await fixture.settingsStore.load()
        XCTAssertEqual(storedDuringDrag.favorites.gridCardScale, 1.3)

        // 超出上限的值在预览阶段即收敛到上限。
        viewModel.previewFavoriteGridCardScale(9)
        XCTAssertEqual(viewModel.favoriteGridCardScale, FavoriteLibrarySettings.maximumGridCardScale)

        viewModel.previewFavoriteGridCardScale(1.8)
        viewModel.commitFavoriteGridCardScale()

        try await waitForSettings {
            let loaded = await fixture.settingsStore.load()
            return loaded.favorites.gridCardScale == 1.8
        }
        XCTAssertEqual(viewModel.favoriteGridCardScale, 1.8)
    }

    func testFavoriteSmartMangaBulkDeleteSettingLoadsAndPersists() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(
            smartMangaBulkDeleteEnabled: false
        )))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.favorites
        await settings.load()

        XCTAssertFalse(viewModel.favoriteSmartMangaBulkDeleteEnabled)

        viewModel.updateFavoriteSmartMangaBulkDeleteEnabled(true)

        try await waitForSettings {
            let loaded = await fixture.settingsStore.load()
            return loaded.favorites.smartMangaBulkDeleteEnabled
        }
        XCTAssertTrue(viewModel.favoriteSmartMangaBulkDeleteEnabled)
    }

    func testFavoriteSmartMangaBadgeSettingLoadsAndPersists() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(
            smartMangaBadgeEnabled: false
        )))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.favorites
        await settings.load()

        XCTAssertFalse(viewModel.favoriteSmartMangaBadgeEnabled)

        viewModel.updateFavoriteSmartMangaBadgeEnabled(true)

        try await waitForSettings {
            let loaded = await fixture.settingsStore.load()
            return loaded.favorites.smartMangaBadgeEnabled
        }
        XCTAssertTrue(viewModel.favoriteSmartMangaBadgeEnabled)
    }

    func testApplyFavoriteBackgroundPersistsImageAndSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.favorites
        await settings.load()
        let imageData = Data(repeating: 6, count: 128)
        let draftSettings = FavoriteBackgroundSettings(
            isEnabled: true,
            scale: 2,
            offsetX: 0.5,
            offsetY: -0.25,
            blurRadius: 14
        )

        let didApply = await viewModel.applyFavoriteBackground(
            imageData: imageData,
            draftSettings: draftSettings
        )

        XCTAssertTrue(didApply)
        let loaded = await fixture.settingsStore.load()
        let imageID = try XCTUnwrap(loaded.favorites.background.imageID)
        XCTAssertTrue(loaded.favorites.background.isEnabled)
        XCTAssertEqual(loaded.favorites.background.scale, 2)
        XCTAssertEqual(loaded.favorites.background.offsetX, 0.5)
        XCTAssertEqual(loaded.favorites.background.offsetY, -0.25)
        XCTAssertEqual(loaded.favorites.background.blurRadius, 14)
        let savedImageData = await fixture.favoriteBackgroundImageStore.loadData(imageID: imageID)
        XCTAssertEqual(savedImageData, imageData)
        XCTAssertEqual(viewModel.favoriteBackground, loaded.favorites.background)
    }

    func testRestoreDefaultFavoriteBackgroundClearsImageAndSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        let imageID = "background"
        try await fixture.favoriteBackgroundImageStore.save(Data(repeating: 7, count: 96), imageID: imageID)
        try await fixture.settingsStore.save(AppSettings(
            favorites: FavoriteLibrarySettings(background: FavoriteBackgroundSettings(isEnabled: true, imageID: imageID))
        ))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.favorites
        await settings.load()
        let didRestore = await viewModel.restoreDefaultFavoriteBackground()

        XCTAssertTrue(didRestore)
        XCTAssertEqual(viewModel.favoriteBackground, FavoriteBackgroundSettings())
        let loadedSettings = await fixture.settingsStore.load()
        XCTAssertEqual(loadedSettings.favorites.background, FavoriteBackgroundSettings())
        let savedImageData = await fixture.favoriteBackgroundImageStore.loadData(imageID: imageID)
        XCTAssertNil(savedImageData)
    }
}

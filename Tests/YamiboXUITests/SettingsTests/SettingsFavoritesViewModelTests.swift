import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

// The favorites page's slice (display options, background, sync behavior) of
// the former SystemSettingsViewModelTests.
@MainActor
final class SettingsFavoritesViewModelTests: XCTestCase {
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
            sortOrder: .displayTitle,
            sortDescending: true,
            showsCategoryCounts: false
        )))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.favorites
        await settings.load()

        XCTAssertEqual(viewModel.favoriteLayoutMode, .staggered)
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

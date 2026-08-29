import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class SettingsGeneralViewModelTests: XCTestCase {
    func testThemeLoadsFromSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(appearance: .init(themePreset: .teal)))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.load()

        XCTAssertEqual(settings.general.themePreset, .teal)
    }

    func testThemeSwitchIsOptimisticAndPersistsAtomically() async throws {
        let fixture = try makeSystemSettingsFixture()
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.load()

        settings.general.updateThemePreset(.rose)

        XCTAssertEqual(settings.general.themePreset, .rose)
        try await waitForSettings {
            await fixture.settingsStore.load().appearance.themePreset == .rose
        }
    }

    func testThemeSaveFailureRollsBackAndSurfacesTheError() async throws {
        let fixture = try makeSystemSettingsFixture()
        let activity = SystemSettingsActivity()
        let viewModel = SettingsGeneralViewModel(
            dependencies: fixture.appContext.settingsDependencies,
            activity: activity,
            updateSettings: { _ in throw AppThemeSettingsTestError.saveFailed }
        )
        viewModel.applyLoadedSettings(AppSettings(appearance: .init(themePreset: .classic)))

        viewModel.updateThemePreset(.standard)

        XCTAssertEqual(viewModel.themePreset, .standard)
        try await waitForSettings {
            viewModel.themePreset == .classic && viewModel.errorMessage != nil
        }
        XCTAssertEqual(viewModel.themePreset, .classic)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}

private enum AppThemeSettingsTestError: LocalizedError {
    case saveFailed

    var errorDescription: String? { "App theme save failed" }
}

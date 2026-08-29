import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class YamiboAppModelAppThemeTests: XCTestCase {
    func testBootstrapLoadsAppThemeBeforePublishingBootstrapState() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(
            appearance: AppAppearanceSettings(themePreset: .teal)
        ))
        let appModel = YamiboAppModel(appContext: fixture.appContext)

        await appModel.bootstrap()

        XCTAssertEqual(appModel.appThemePreset, .teal)
        XCTAssertEqual(appModel.bootstrapState?.settings.appearance.themePreset, .teal)
    }

    func testSettingsStoreChangeRefreshesAppThemeAtRuntime() async throws {
        let fixture = try makeSystemSettingsFixture()
        let appModel = YamiboAppModel(appContext: fixture.appContext)
        await appModel.bootstrap()
        XCTAssertEqual(appModel.appThemePreset, .classic)
        await Task.yield()

        try await fixture.settingsStore.save(AppSettings(
            appearance: AppAppearanceSettings(themePreset: .rose)
        ))

        try await waitForSettings {
            appModel.appThemePreset == .rose
        }
        XCTAssertEqual(appModel.appThemePreset, .rose)
    }
}

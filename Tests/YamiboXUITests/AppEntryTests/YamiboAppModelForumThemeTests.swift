import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class YamiboAppModelForumThemeTests: XCTestCase {
    func testBootstrapLoadsForumThemeBeforePublishingBootstrapState() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(
            forumAppearance: ForumAppearanceSettings(themePreset: .teal)
        ))
        let appModel = YamiboAppModel(appContext: fixture.appContext)

        await appModel.bootstrap()

        XCTAssertEqual(appModel.forumThemePreset, .teal)
        XCTAssertEqual(appModel.bootstrapState?.settings.forumAppearance.themePreset, .teal)
    }

    func testSettingsStoreChangeRefreshesForumThemeAtRuntime() async throws {
        let fixture = try makeSystemSettingsFixture()
        let appModel = YamiboAppModel(appContext: fixture.appContext)
        await appModel.bootstrap()
        XCTAssertEqual(appModel.forumThemePreset, .classic)
        await Task.yield()

        try await fixture.settingsStore.save(AppSettings(
            forumAppearance: ForumAppearanceSettings(themePreset: .rose)
        ))

        try await waitForSettings {
            appModel.forumThemePreset == .rose
        }
        XCTAssertEqual(appModel.forumThemePreset, .rose)
    }
}

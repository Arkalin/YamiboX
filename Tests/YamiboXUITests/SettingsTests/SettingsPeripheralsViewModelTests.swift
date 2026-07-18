import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

// The peripherals page's slice of the former SystemSettingsViewModelTests.
// Construction still goes through the `SystemSettingsViewModel` composition
// root so `load()` exercises the real one-read-for-all-pages wiring.
@MainActor
final class SettingsPeripheralsViewModelTests: XCTestCase {
    func testLoadReadsApplePencilPageTurnSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        let savedSettings = ApplePencilPageTurnSettings(
            isEnabled: true,
            behavior: .doubleTapNextSqueezePrevious
        )
        try await fixture.settingsStore.save(AppSettings(system: SystemSettings(applePencilPageTurn: savedSettings)))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.load()

        XCTAssertEqual(settings.peripherals.applePencilPageTurn, savedSettings)
    }

    func testUpdateApplePencilEnabledPersistsSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings())

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.peripherals
        await settings.load()
        viewModel.updateApplePencilPageTurnEnabled(true)

        try await waitForSettings {
            let loaded = await fixture.settingsStore.load()
            return loaded.system.applePencilPageTurn.isEnabled
        }
        XCTAssertTrue(viewModel.applePencilPageTurn.isEnabled)
    }

    func testUpdateApplePencilBehaviorPersistsSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings())

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.peripherals
        await settings.load()
        viewModel.updateApplePencilPageTurnBehavior(.doubleTapNextSqueezePrevious)

        try await waitForSettings {
            let loaded = await fixture.settingsStore.load()
            return loaded.system.applePencilPageTurn.behavior == .doubleTapNextSqueezePrevious
        }
        XCTAssertEqual(viewModel.applePencilPageTurn.behavior, .doubleTapNextSqueezePrevious)
    }
}

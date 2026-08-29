import Foundation
import Testing
@testable import YamiboXCore

@Suite("SettingsTests: System Settings")
struct SystemSettingsTests {
    @Test func appearanceDefaultsToClassic() {
        #expect(AppAppearanceSettings().themePreset == .classic)
        #expect(AppSettings().appearance.themePreset == .classic)
    }

    @Test func appThemePresetsRoundTripThroughCodable() throws {
        for preset in AppThemePreset.allCases {
            let settings = AppAppearanceSettings(themePreset: preset)
            let encoded = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppAppearanceSettings.self, from: encoded)

            #expect(decoded == settings)
        }
    }

    @Test func legacyForumAppearanceKeyIsIgnoredAndDefaultsToClassic() throws {
        let original = AppSettings(
            system: SystemSettings(homePage: .favorites, usesDataSaverMode: true),
            appearance: AppAppearanceSettings(themePreset: .teal)
        )
        let encoded = try JSONEncoder().encode(original)
        guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw YamiboError.underlying("Failed to prepare legacy settings fixture")
        }
        payload["forumAppearance"] = payload.removeValue(forKey: "appearance")

        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.system.homePage == .favorites)
        #expect(decoded.system.usesDataSaverMode == true)
        #expect(decoded.appearance.themePreset == .classic)
        #expect(decoded.boardReader == original.boardReader)
    }

    @Test func appSettingsEncodeOnlyTheNewAppearanceKey() throws {
        let encoded = try JSONEncoder().encode(AppSettings(appearance: .init(themePreset: .teal)))
        let payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(payload?["appearance"] != nil)
        #expect(payload?["forumAppearance"] == nil)
    }

    @Test func missingExistingAppSettingsFieldStillFailsDecoding() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw YamiboError.underlying("Failed to prepare malformed settings fixture")
        }
        payload.removeValue(forKey: "manga")
        let malformedData = try JSONSerialization.data(withJSONObject: payload)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppSettings.self, from: malformedData)
        }
    }

    @Test func applicationSettingsResetRestoresClassicAppearance() async throws {
        let suiteName = "app-appearance-reset-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw YamiboError.underlying("Failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults, key: "settings")
        try await store.save(AppSettings(appearance: .init(themePreset: .rose)))

        try await store.reset()

        #expect(await store.load().appearance.themePreset == .classic)
    }

    @Test func appAppearanceStaysLocalWhenApplyingWebDAVSettings() {
        let local = AppSettings(appearance: .init(themePreset: .rose))
        let synced = WebDAVSyncedAppSettings(settings: local)

        #expect(synced == .init(homePage: .forum, webBrowser: WebBrowserSettings()))
        #expect(synced.applying(to: local).appearance.themePreset == .rose)
    }

    @Test func enhancedCheckInDefaultsToDisabled() {
        #expect(SystemSettings().enhancedCheckInEnabled == false)
    }

    @Test func legacyAppSettingsDecodeWithEnhancedCheckInDisabled() throws {
        let original = AppSettings(system: SystemSettings(
            homePage: .favorites,
            usesDataSaverMode: true,
            enhancedCheckInEnabled: true
        ))
        let encoded = try JSONEncoder().encode(original)
        guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var system = payload["system"] as? [String: Any]
        else {
            throw YamiboError.underlying("Failed to prepare legacy settings fixture")
        }

        system.removeValue(forKey: "enhancedCheckInEnabled")
        payload["system"] = system

        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.system.homePage == .favorites)
        #expect(decoded.system.usesDataSaverMode == true)
        #expect(decoded.system.enhancedCheckInEnabled == false)
        #expect(decoded.boardReader == original.boardReader)
    }
}

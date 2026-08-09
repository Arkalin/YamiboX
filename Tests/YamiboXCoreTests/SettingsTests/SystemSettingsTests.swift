import Foundation
import Testing
@testable import YamiboXCore

@Suite("SettingsTests: System Settings")
struct SystemSettingsTests {
    @Test func forumAppearanceDefaultsToClassic() {
        #expect(ForumAppearanceSettings().themePreset == .classic)
        #expect(AppSettings().forumAppearance.themePreset == .classic)
    }

    @Test func forumThemePresetsRoundTripThroughCodable() throws {
        for preset in ForumThemePreset.allCases {
            let settings = ForumAppearanceSettings(themePreset: preset)
            let encoded = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(ForumAppearanceSettings.self, from: encoded)

            #expect(decoded == settings)
        }
    }

    @Test func legacyAppSettingsDecodeWithClassicForumAppearance() throws {
        let original = AppSettings(
            system: SystemSettings(homePage: .favorites, usesDataSaverMode: true),
            forumAppearance: ForumAppearanceSettings(themePreset: .teal)
        )
        let encoded = try JSONEncoder().encode(original)
        guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw YamiboError.underlying("Failed to prepare legacy settings fixture")
        }
        payload.removeValue(forKey: "forumAppearance")

        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        #expect(decoded.system.homePage == .favorites)
        #expect(decoded.system.usesDataSaverMode == true)
        #expect(decoded.forumAppearance.themePreset == .classic)
        #expect(decoded.boardReader == original.boardReader)
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

    @Test func applicationSettingsResetRestoresClassicForumAppearance() async throws {
        let suiteName = "forum-appearance-reset-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw YamiboError.underlying("Failed to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults, key: "settings")
        try await store.save(AppSettings(forumAppearance: .init(themePreset: .rose)))

        try await store.reset()

        #expect(await store.load().forumAppearance.themePreset == .classic)
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

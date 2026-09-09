import Foundation
import Testing
@testable import YamiboXCore

@Suite("SettingsTests: System Settings")
struct SystemSettingsTests {
    @Test func homeFavoritesFilterDefaultsOffAndRoundTrips() throws {
        #expect(SystemSettings().homeShowsOnlyFavorites == false)
        let legacy = Data(#"{"homePage":"favorites","usesDataSaverMode":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SystemSettings.self, from: legacy)
        #expect(decoded.homeShowsOnlyFavorites == false)
        #expect(decoded.homePage == .favorites)
        #expect(decoded.usesDataSaverMode)

        for enabled in [false, true] {
            let original = AppSettings(system: .init(homeShowsOnlyFavorites: enabled))
            let encoded = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(AppSettings.self, from: encoded) == original)
        }
    }

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

    @Test func atomicUpdatesPreserveIndependentFieldsFromConcurrentWriters() async throws {
        let suiteName = "settings-atomic-writers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults, key: "settings")

        async let home = store.update { $0.system.homePage = .favorites }
        async let theme = store.update { $0.appearance.themePreset = .rose }
        async let novel = store.update { $0.novelReader.fontScale = 1.2 }
        async let manga = store.update { $0.manga.brightness = 0.6 }
        async let layout = store.update { $0.favorites.layoutMode = .fixedGrid }
        _ = try await (home, theme, novel, manga, layout)

        let saved = await store.load()
        #expect(saved.system.homePage == .favorites)
        #expect(saved.appearance.themePreset == .rose)
        #expect(saved.novelReader.fontScale == 1.2)
        #expect(saved.manga.brightness == 0.6)
        #expect(saved.favorites.layoutMode == .fixedGrid)
    }

    @Test func appAppearanceStaysLocalWhenApplyingWebDAVSettings() {
        let local = AppSettings(appearance: .init(themePreset: .rose))
        let synced = WebDAVSyncedAppSettings(settings: local)

        #expect(synced == .init(homePage: .home, webBrowser: WebBrowserSettings()))
        #expect(synced.applying(to: local).appearance.themePreset == .rose)
    }

    @Test func enhancedCheckInDefaultsToDisabled() {
        #expect(SystemSettings().enhancedCheckInEnabled == false)
    }

    @Test func homePageDefaultsAndSavedChoicesRoundTrip() throws {
        #expect(SystemSettings().homePage == .home)
        for page in AppHomePage.allCases {
            let data = try JSONEncoder().encode(SystemSettings(homePage: page))
            #expect(try JSONDecoder().decode(SystemSettings.self, from: data).homePage == page)
        }
        #expect(try JSONDecoder().decode(SystemSettings.self, from: Data("{}".utf8)).homePage == .forum)
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

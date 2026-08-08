import Foundation
import Testing
@testable import YamiboXCore

@Suite("SettingsTests: System Settings")
struct SystemSettingsTests {
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

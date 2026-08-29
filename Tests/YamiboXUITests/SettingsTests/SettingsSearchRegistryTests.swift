import XCTest
@testable import YamiboXUI

@MainActor
final class SettingsSearchRegistryTests: XCTestCase {
    func testAppThemeSearchEntryRoutesToGeneral() throws {
        let entry = try XCTUnwrap(SettingsSearchRegistry.entries.first { $0.id == "general.appearance" })

        XCTAssertEqual(entry.category, .general)
        XCTAssertFalse(SettingsSearchRegistry.entries.contains { $0.id == "forum.appearance" })
    }
}

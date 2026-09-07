import XCTest
@testable import YamiboXUI

@MainActor
final class SettingsSearchRegistryTests: XCTestCase {
    func testFavoriteItemTapActionIsSearchable() throws {
        let entry = try XCTUnwrap(SettingsSearchRegistry.entries.first { $0.id == "favorites.item_tap_action" })
        XCTAssertEqual(entry.category, .favorites)
        for keyword in ["点击", "小说", "智能漫画", "查看详情", "阅读"] {
            XCTAssertTrue(SettingsSearchRegistry.search(keyword).contains { $0.id == entry.id })
        }
    }

    func testAppThemeSearchEntryRoutesToGeneral() throws {
        let entry = try XCTUnwrap(SettingsSearchRegistry.entries.first { $0.id == "general.appearance" })

        XCTAssertEqual(entry.category, .general)
        XCTAssertFalse(SettingsSearchRegistry.entries.contains { $0.id == "forum.appearance" })
    }
}

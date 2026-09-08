import XCTest
@testable import YamiboXUI

@MainActor
final class SettingsSearchRegistryTests: XCTestCase {
    func testHomeFavoritesFilterIsSearchable() throws {
        let entry = try XCTUnwrap(SettingsSearchRegistry.entries.first { $0.id == "home.only_favorites" })
        XCTAssertEqual(entry.category, .home)
        XCTAssertEqual(entry.title, "只显示已收藏项")
        XCTAssertEqual(entry.category.title, "主页")
        XCTAssertTrue(SettingsCategory.allCases.contains(.home))
        for keyword in ["主页", "收藏", "继续阅读", "此前阅读"] {
            XCTAssertTrue(SettingsSearchRegistry.search(keyword).contains { $0.id == entry.id })
        }
    }

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

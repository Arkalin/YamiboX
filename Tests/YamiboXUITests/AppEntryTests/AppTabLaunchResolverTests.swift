import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class AppTabLaunchResolverTests: XCTestCase {
    func testResolvesFavoritesFromSavedHomePage() {
        let tab = AppTabLaunchResolver.resolveInitialTab(
            environment: [:],
            homePage: .favorites
        )

        XCTAssertEqual(tab, .favorites)
    }

    func testResolvesForumFromSavedHomePage() {
        let tab = AppTabLaunchResolver.resolveInitialTab(
            environment: [:],
            homePage: .forum
        )

        XCTAssertEqual(tab, .forum)
    }

    func testDebugStartTabOverrideWinsOverSavedHomePage() {
        let tab = AppTabLaunchResolver.resolveInitialTab(
            environment: ["START_TAB": "favorites"],
            homePage: .forum
        )

        XCTAssertEqual(tab, .favorites)
    }
}

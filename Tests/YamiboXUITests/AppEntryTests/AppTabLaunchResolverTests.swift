import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class AppTabLaunchResolverTests: XCTestCase {
    func testResolvesHomeAndKeepsDebugOverrides() {
        XCTAssertEqual(AppTabLaunchResolver.resolveInitialTab(environment: [:]), .home)
        XCTAssertEqual(AppTabLaunchResolver.resolveInitialTab(environment: [:], homePage: .home), .home)
        XCTAssertEqual(AppTabLaunchResolver.resolveInitialTab(environment: ["START_TAB": "home"], homePage: .favorites), .home)
        XCTAssertEqual(AppTabLaunchResolver.resolveInitialTab(environment: ["START_TAB": "forum"], homePage: .home), .forum)
    }
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

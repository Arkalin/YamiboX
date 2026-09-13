import SwiftUI
import XCTest
@testable import YamiboXUI

@MainActor
final class MineSidebarNavigationStateTests: XCTestCase {
    func testInitialStateShowsRootWithBlankDetail() {
        let state = MineSidebarNavigationState()
        XCTAssertTrue(state.sidebarPath.isEmpty)
        XCTAssertNil(state.section)
        XCTAssertNil(state.detail)
        XCTAssertFalse(state.isSelectingLikes)
        XCTAssertEqual(state.preferredCompactColumn, .sidebar)
    }

    func testLibraryEntriesOpenContentWithoutPushingCategories() {
        for (entry, detail) in [(MineSidebarSection.history, MineSidebarDetail.history(.all)), (.likes, .likes(.all))] {
            let state = MineSidebarNavigationState()
            state.setSidebarPath([entry])
            XCTAssertTrue(state.sidebarPath.isEmpty)
            XCTAssertNil(state.section)
            XCTAssertEqual(state.detail, detail)
            XCTAssertEqual(state.preferredCompactColumn, .detail)
            state.show(entry == .history ? .history(.novel) : .likes(.manga))
            XCTAssertTrue(state.sidebarPath.isEmpty)
            state.show(.downloads)
            state.setSidebarPath([entry])
            XCTAssertEqual(state.detail, detail)
        }
    }

    func testSettingsStillPushesItsSidebarAndReturnsToEmptyRoot() {
        let state = MineSidebarNavigationState()
        state.setSidebarPath([.settings])
        XCTAssertEqual(state.sidebarPath, [.settings])
        XCTAssertEqual(state.detail, .settings(.category(.general)))
        XCTAssertEqual(state.preferredCompactColumn, .sidebar)
        state.show(.settings(.category(.reading)))
        state.setSidebarPath([.settings])
        XCTAssertEqual(state.detail, .settings(.category(.reading)))
        XCTAssertEqual(state.preferredCompactColumn, .detail)
        state.show(.history(.all))
        XCTAssertEqual(state.detail, .settings(.category(.reading)))
        state.setSidebarPath([])
        XCTAssertNil(state.detail)
        XCTAssertTrue(state.sidebarPath.isEmpty)
        state.setSidebarPath([.settings])
        XCTAssertEqual(state.detail, .settings(.category(.general)))
    }

    func testRootFeaturesAndLibraryFiltersShareTheDetailColumn() {
        let state = MineSidebarNavigationState()
        for detail in [MineSidebarDetail.profile, .messages, .downloads, .history(.novel), .likes(.manga)] {
            state.show(detail)
            XCTAssertEqual(state.detail, detail)
            XCTAssertTrue(state.sidebarPath.isEmpty)
            XCTAssertEqual(state.preferredCompactColumn, .detail)
        }
        state.show(.settings(.about))
        XCTAssertEqual(state.detail, .likes(.manga))
    }

    func testLikesSelectionBlocksFiltersAndFeatureChangesUntilDone() {
        let state = MineSidebarNavigationState()
        state.show(.likes(.manga))
        state.isSelectingLikes = true
        state.show(.likes(.novel))
        state.show(.history(.all))
        state.setSidebarPath([])
        state.setSidebarPath([.settings])
        XCTAssertTrue(state.sidebarPath.isEmpty)
        XCTAssertEqual(state.detail, .likes(.manga))
        XCTAssertTrue(state.isSelectingLikes)
        state.isSelectingLikes = false
        state.show(.likes(.novel))
        XCTAssertEqual(state.detail, .likes(.novel))
        state.setSidebarPath([.settings])
        XCTAssertEqual(state.section, .settings)
    }

    func testStateInstancesDoNotShareNavigationOrSelection() {
        let first = MineSidebarNavigationState()
        let second = MineSidebarNavigationState()
        first.show(.likes(.manga))
        first.isSelectingLikes = true
        second.show(.history(.novel))
        XCTAssertEqual(first.detail, .likes(.manga))
        XCTAssertTrue(first.isSelectingLikes)
        XCTAssertEqual(second.detail, .history(.novel))
        XCTAssertFalse(second.isSelectingLikes)
        second.returnToRoot()
        XCTAssertEqual(first.detail, .likes(.manga))
    }

    func testCompactLibraryReturnGoesStraightToMine() {
        let state = MineSidebarNavigationState()
        state.show(.history(.manga))
        state.preferredCompactColumn = .sidebar
        XCTAssertTrue(state.sidebarPath.isEmpty)
        XCTAssertNil(state.section)
        state.setSidebarPath([.likes])
        XCTAssertEqual(state.preferredCompactColumn, .detail)
        XCTAssertEqual(state.detail, .likes(.all))
    }

    func testSignOutClearsAccountDetailsButPreservesLibraryFilter() {
        for detail in [MineSidebarDetail.profile, .messages] {
            let state = MineSidebarNavigationState()
            state.show(detail)
            state.accountDidSignOut()
            XCTAssertNil(state.detail)
            XCTAssertEqual(state.preferredCompactColumn, .sidebar)
        }
        let state = MineSidebarNavigationState()
        state.show(.history(.manga))
        state.accountDidSignOut()
        XCTAssertEqual(state.detail, .history(.manga))
    }

    func testDetailIdentityRemainsStableAcrossFilters() {
        for filter in BrowsingHistoryFilter.allCases {
            XCTAssertEqual(MineSidebarDetail.history(filter).identity, .history)
        }
        for filter in LikeWorkFilter.allCases {
            XCTAssertEqual(MineSidebarDetail.likes(filter).identity, .likes)
        }
        let features: [MineSidebarDetail] = [.profile, .messages, .downloads,
            .history(.all), .likes(.all), .settings(.category(.general))]
        XCTAssertEqual(Set(features.map(\.identity)).count, features.count)
    }
}

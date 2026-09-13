import XCTest
import UIKit

@MainActor
final class MineSidebarInteractionTests: XCTestCase {
    func testFavoritesContentCollectionOpensAndReturnsOnIPad() throws {
        try assertFavoritesCollectionNavigation(layout: "rowCard")
    }

    func testFavoritesGridCollectionOpensAndReturnsOnIPad() throws {
        try assertFavoritesCollectionNavigation(layout: "fixedGrid")
    }

    private func assertFavoritesCollectionNavigation(layout: String) throws {
        try withLandscapeFixture([
            "MINE_SIDEBAR_ALIGNMENT_FIXTURE": "1",
            "FAVORITES_COLLECTION_TAP_FIXTURE": "1",
            "FAVORITES_COLLECTION_LAYOUT": layout
        ]) { app in
            app.buttons["收藏"].firstMatch.tap()
            let sidebar = element("favorites.sidebar", in: app)
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            let collectionName = "合集点击验收"
            let candidates = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", collectionName))
            XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 5))
            let card = try XCTUnwrap(candidates.allElementsBoundByIndex.first {
                $0.frame.midX > sidebar.frame.maxX && $0.isHittable
            }, "Must tap the content collection, not the sidebar link.\n\(app.debugDescription)")
            attach(app, "Favorites collection before content tap")
            card.tap()
            let collectionBar = app.navigationBars[collectionName]
            let opened = collectionBar.waitForExistence(timeout: 5)
            attach(app, "Favorites collection after content tap")
            XCTAssertTrue(opened, "Content collection must push its destination.\n\(app.debugDescription)")
            let sidebarCollection = sidebar.buttons.matching(NSPredicate(format: "label CONTAINS %@", collectionName)).firstMatch
            let sidebarCategory = sidebar.buttons["默认"].firstMatch
            if opened {
                XCTAssertTrue(sidebarCollection.isSelected)
                XCTAssertFalse(sidebarCategory.isSelected)
                let back = nativeBackButton(in: app, title: collectionName, destination: "默认")
                waitUntilHittable(back)
                back.tap()
                XCTAssertTrue(collectionBar.waitForNonExistence(timeout: 5))
                waitUntilHittable(card)
                XCTAssertTrue(sidebarCategory.isSelected)
                XCTAssertFalse(sidebarCollection.isSelected)
            }
            waitUntilHittable(sidebarCollection)
            sidebarCollection.tap()
            XCTAssertTrue(collectionBar.waitForExistence(timeout: 5), "Sidebar collection must still navigate")
            attach(app, "Favorites collection opened from sidebar")
            XCTAssertTrue(sidebarCollection.isSelected)
            sidebarCategory.tap()
            XCTAssertTrue(collectionBar.waitForNonExistence(timeout: 5))
            waitUntilHittable(card)
            XCTAssertTrue(sidebarCategory.isSelected)
            card.tap()
            XCTAssertTrue(collectionBar.waitForExistence(timeout: 5))
            XCTAssertTrue(sidebarCollection.isSelected)
        }
    }

    func testSidebarTitleMatchesFavoritesAfterTabSwitches() throws {
        try withLandscapeFixture(["MINE_SIDEBAR_ALIGNMENT_FIXTURE": "1"]) { app in
            for visit in 0..<3 {
                // Compare the same visit count: the fixture starts on Mine.
                let mineTitle = app.navigationBars["我的"].staticTexts["我的"].firstMatch
                waitUntilHittable(mineTitle)
                let mineY = mineTitle.frame.midY
                app.buttons["收藏"].firstMatch.tap()
                let favoritesTitle = app.navigationBars["收藏"].staticTexts["收藏"].firstMatch
                waitUntilHittable(favoritesTitle)
                XCTAssertEqual(mineY, favoritesTitle.frame.midY, accuracy: 1,
                    "Sidebar titles must align on visit \(visit)")
                app.buttons["我的"].firstMatch.tap()
            }
            attach(app, "Mine title aligns with Favorites after repeated tab switches")
        }
    }

    func testRegularSidebarExtendsAboveFloatingTabsWithoutOverlappingTitles() throws {
        try withLandscapeFixture { app in
            let tab = app.buttons["验收页"].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            let workspace = element("mine.sidebar.workspace", in: app)
            XCTAssertLessThanOrEqual(workspace.frame.minY, tab.frame.minY)
            let sidebar = element("mine.sidebar.root", in: app)
            XCTAssertEqual(sidebar.frame.minY, app.frame.minY, accuracy: 1)
            let title = app.navigationBars["我的"].staticTexts["我的"].firstMatch
            XCTAssertTrue(title.exists)
            XCTAssertGreaterThanOrEqual(title.frame.minY, tab.frame.maxY)
            attach(app, "Mine extends behind floating tabs")

            element("mine.sidebar.settings", in: app).tap()
            XCTAssertTrue(element("settings.sidebar", in: app).waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(workspace.frame.minY, tab.frame.minY)
            assertNoCloseButton(app)
            attach(app, "Embedded settings shares the full-height Mine workspace")
        }
    }

    func testCompactTraitHarnessUsesSettingsSubmenuAndDirectLibraryDetails() throws {
        // This exercises compact traits, not the OS's physical window-resizing path.
        try withLandscapeFixture(["MINE_SIDEBAR_COMPACT_FIXTURE": "1"]) { app in
            let cases: [(section: String, sidebarID: String, title: String, detailTitle: String, categoryID: String?)] = [
                ("settings", "settings.sidebar", "设置", "通用", nil)
            ]
            for scenario in cases {
                waitUntilHittable(element("mine.sidebar.settings", in: app))
                element("mine.sidebar.\(scenario.section)", in: app).tap()
                let sidebar = element(scenario.sidebarID, in: app)
                let category = scenario.categoryID.map { element($0, in: app) }
                    ?? sidebar.buttons[scenario.detailTitle].firstMatch
                waitUntilHittable(category)
                let detailBar = app.navigationBars[scenario.detailTitle]
                let back = detailBar.buttons.matching(NSPredicate(
                    format: "label IN %@",
                    [scenario.title, "返回", "Back", "侧边栏", "Sidebar"]
                )).firstMatch
                waitUntilHittable(back, false)
                assertNoCloseButton(app)
                attach(app, "Compact traits \(scenario.section) shows categories before default detail")

                category.tap()
                waitUntilHittable(back)
                waitUntilHittable(category, false)
                assertNoCloseButton(app)

                back.tap()
                waitUntilHittable(category)
                waitUntilHittable(back, false)
                backToMine(app, title: scenario.title)
                waitUntilHittable(element("mine.sidebar.settings", in: app))
                waitUntilHittable(category, false)
            }
            for (section, title, pickerID) in [
                ("history", "浏览记录", "history.category.picker"),
                ("likes", "喜欢", "likes.category.picker")
            ] {
                let entry = element("mine.sidebar.\(section)", in: app)
                waitUntilHittable(entry)
                entry.tap()
                let picker = app.segmentedControls[pickerID]
                waitUntilHittable(picker)
                XCTAssertTrue(picker.buttons["全部"].isSelected)
                XCTAssertFalse(element("mine.sidebar.\(section).categories", in: app).exists)
                waitUntilHittable(element("mine.sidebar.settings", in: app), false)
                assertNoCloseButton(app)
                let back = nativeBackButton(in: app, title: title, destination: "我的")
                waitUntilHittable(back)
                back.tap()
                waitUntilHittable(element("mine.sidebar.settings", in: app))
                waitUntilHittable(picker, false)
            }
            attach(app, "Compact traits return directly from library detail to Mine root")
        }
    }

    func testPhoneRetainsPushedFeatureNavigation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let app = XCUIApplication()
        app.launchEnvironment["MINE_SIDEBAR_FIXTURE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("mine.sidebar.workspace", in: app).exists)
        for (entry, title) in [("浏览记录", "浏览记录"), ("我的喜欢", "喜欢"), ("设置", "设置")] {
            app.buttons[entry].firstMatch.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            XCTAssertFalse(element("mine.sidebar.workspace", in: app).exists)
            let back = app.navigationBars[title].buttons["我的"]
            XCTAssertTrue(back.exists)
            back.tap()
            XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
        }
        attach(app, "iPhone retains Mine push navigation")
    }

    func testSettingsSidebarPushesInPlaceAndReturnsToEmptyRoot() throws {
        try withLandscapeFixture { app in
            assertRoot(app)
            element("mine.sidebar.settings", in: app).tap()
            XCTAssertTrue(element("settings.sidebar", in: app).waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["通用"].waitForExistence(timeout: 5))
            assertNoCloseButton(app)
            XCTAssertEqual(app.navigationBars.matching(identifier: "设置").count, 1)
            attach(app, "Mine settings sidebar with shared detail")

            backToMine(app, title: "设置")
            assertRoot(app)
            XCTAssertFalse(app.navigationBars["通用"].exists)
        }
    }

    func testHistoryUsesTopCategoryPickerAndKeepsMineRootSidebar() throws {
        try withLandscapeFixture { app in
            element("mine.sidebar.history", in: app).tap()
            let picker = app.segmentedControls["history.category.picker"]
            waitUntilHittable(picker)
            XCTAssertTrue(app.navigationBars["浏览记录"].waitForExistence(timeout: 5))
            XCTAssertTrue(picker.buttons["全部"].isSelected)
            XCTAssertFalse(element("mine.sidebar.history.categories", in: app).exists)
            XCTAssertTrue(element("mine.sidebar.history", in: app).isSelected)
            waitUntilHittable(element("mine.sidebar.settings", in: app))
            picker.buttons["小说"].tap()
            XCTAssertTrue(picker.buttons["小说"].isSelected)
            XCTAssertTrue(app.navigationBars["浏览记录"].exists)
            assertNoCloseButton(app)
            picker.buttons["漫画"].tap()
            XCTAssertTrue(picker.buttons["漫画"].isSelected)
            XCTAssertTrue(element("mine.sidebar.history", in: app).isSelected)
            XCTAssertTrue(app.navigationBars["浏览记录"].exists)
            attach(app, "Mine history top categories retain the root sidebar")

            element("mine.sidebar.likes", in: app).tap()
            XCTAssertTrue(app.segmentedControls["likes.category.picker"].waitForExistence(timeout: 5))
            XCTAssertTrue(element("mine.sidebar.likes", in: app).isSelected)
            XCTAssertFalse(element("mine.sidebar.history", in: app).isSelected)
            element("mine.sidebar.history", in: app).tap()
            waitUntilHittable(picker)
            XCTAssertTrue(picker.buttons["全部"].isSelected)
            XCTAssertTrue(app.navigationBars["浏览记录"].exists)
        }
    }

    func testLikesSelectionDisablesCategoriesAndTabSwitchRetainsSelection() throws {
        try withLandscapeFixture { app in
            element("mine.sidebar.likes", in: app).tap()
            let novel = app.buttons["like.work.novel.mine-novel"]
            let manga = app.buttons["like.work.manga.侧栏验收漫画"]
            XCTAssertTrue(novel.waitForExistence(timeout: 10))
            XCTAssertTrue(manga.exists)
            let picker = app.segmentedControls["likes.category.picker"]
            waitUntilHittable(picker)
            XCTAssertFalse(element("mine.sidebar.likes.categories", in: app).exists)
            waitUntilHittable(element("mine.sidebar.settings", in: app))
            picker.buttons["漫画"].tap()
            XCTAssertTrue(picker.buttons["漫画"].isSelected)
            XCTAssertTrue(app.navigationBars["喜欢"].waitForExistence(timeout: 5))
            XCTAssertFalse(novel.exists)
            XCTAssertTrue(manga.exists)
            assertNoCloseButton(app)

            app.buttons["选择"].tap()
            let novelCategory = picker.buttons["小说"]
            XCTAssertFalse(novelCategory.isEnabled)
            app.buttons["全选"].tap()
            XCTAssertTrue(app.buttons["删除 1 项"].waitForExistence(timeout: 5))

            switchAwayAndBack(app)
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["删除 1 项"].exists)
            XCTAssertFalse(novelCategory.isEnabled)
            XCTAssertFalse(picker.buttons["全部"].isEnabled)
            attach(app, "Mine likes selection and category lock survive tab switch")

            app.buttons["完成"].tap()
            XCTAssertTrue(novelCategory.isEnabled)
            novelCategory.tap()
            XCTAssertTrue(app.navigationBars["喜欢"].waitForExistence(timeout: 5))
            XCTAssertTrue(novelCategory.isSelected)
            XCTAssertTrue(novel.exists)
            XCTAssertFalse(manga.exists)

            switchAwayAndBack(app)
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["喜欢"].exists)
            XCTAssertTrue(novelCategory.isSelected)
            XCTAssertTrue(novel.exists)
            XCTAssertFalse(manga.exists)
            attach(app, "Mine likes restored after tab switch")

            element("mine.sidebar.history", in: app).tap()
            XCTAssertTrue(app.segmentedControls["history.category.picker"].waitForExistence(timeout: 5))
            element("mine.sidebar.likes", in: app).tap()
            waitUntilHittable(picker)
            XCTAssertTrue(picker.buttons["全部"].isSelected)
            XCTAssertTrue(novel.waitForExistence(timeout: 5))
            XCTAssertTrue(manga.exists)
        }
    }

    func testLikesSearchClearsAndCategoryPickerReturnsAfterPoppingWork() throws {
        try withLandscapeFixture { app in
            element("mine.sidebar.likes", in: app).tap()
            let novel = app.buttons["like.work.novel.mine-novel"]
            let manga = app.buttons["like.work.manga.侧栏验收漫画"]
            XCTAssertTrue(novel.waitForExistence(timeout: 10))
            XCTAssertTrue(manga.exists)

            let search = app.searchFields["搜索作品"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("小说")
            XCTAssertTrue(novel.waitForExistence(timeout: 5))
            XCTAssertTrue(manga.waitForNonExistence(timeout: 5))
            attach(app, "Mine likes search filters works")

            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
            XCTAssertTrue(manga.waitForExistence(timeout: 5))
            XCTAssertTrue(novel.exists)
            search.typeText("\n")

            novel.tap()
            let excerpt = app.buttons["like.item.mine-fixture-novel-like"]
            XCTAssertTrue(excerpt.waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["侧栏验收小说"].exists)
            let picker = app.segmentedControls["likes.category.picker"]
            waitUntilHittable(picker, false)
            waitUntilHittable(element("mine.sidebar.settings", in: app))

            let back = nativeBackButton(in: app, title: "侧栏验收小说", destination: "喜欢")
            waitUntilHittable(back)
            back.tap()
            waitUntilHittable(picker)
            XCTAssertTrue(excerpt.waitForNonExistence(timeout: 5))
            picker.buttons["漫画"].tap()
            XCTAssertTrue(app.navigationBars["喜欢"].waitForExistence(timeout: 5))
            XCTAssertTrue(picker.buttons["漫画"].isSelected)
            XCTAssertTrue(manga.waitForExistence(timeout: 5))
            XCTAssertTrue(excerpt.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars["侧栏验收小说"].exists)
            XCTAssertFalse(novel.exists)
            assertNoCloseButton(app)
            attach(app, "Mine top category picker filters after returning from work detail")
        }
    }

    func testRootMenuReplacesPushedLibraryDetailAndResetsCategoryOnReentry() throws {
        try withLandscapeFixture { app in
            element("mine.sidebar.likes", in: app).tap()
            let picker = app.segmentedControls["likes.category.picker"]
            waitUntilHittable(picker)
            picker.buttons["小说"].tap()
            let novel = app.buttons["like.work.novel.mine-novel"]
            XCTAssertTrue(novel.waitForExistence(timeout: 5))
            novel.tap()
            let excerpt = app.buttons["like.item.mine-fixture-novel-like"]
            XCTAssertTrue(excerpt.waitForExistence(timeout: 5))

            let downloads = element("mine.sidebar.downloads", in: app)
            waitUntilHittable(downloads)
            downloads.tap()
            XCTAssertTrue(app.navigationBars["下载队列"].waitForExistence(timeout: 5))
            XCTAssertTrue(excerpt.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars["侧栏验收小说"].exists)
            waitUntilHittable(element("mine.sidebar.history", in: app))

            element("mine.sidebar.likes", in: app).tap()
            waitUntilHittable(picker)
            XCTAssertTrue(picker.buttons["全部"].isSelected)
            XCTAssertTrue(novel.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["like.work.manga.侧栏验收漫画"].exists)
            XCTAssertFalse(excerpt.exists)
            XCTAssertTrue(app.navigationBars["喜欢"].exists)
            assertNoCloseButton(app)
            attach(app, "Mine root menu replaces pushed work and reopens all liked works")
        }
    }

    private func withLandscapeFixture(
        _ environment: [String: String] = [:],
        _ test: (XCUIApplication) throws -> Void
    ) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires iPad sidebar layout")
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = originalOrientation }
        let app = XCUIApplication()
        app.launchEnvironment["MINE_SIDEBAR_FIXTURE"] = "1"
        app.launchEnvironment.merge(environment) { _, value in value }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(element("mine.sidebar.root", in: app).waitForExistence(timeout: 10))
        try test(app)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntilHittable(
        _ element: XCUIElement,
        _ isHittable: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (element.exists && element.isHittable) == isHittable
            },
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    private func assertRoot(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element("mine.sidebar.root", in: app).waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element("mine.detail.empty", in: app).waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(app.navigationBars.matching(identifier: "我的").count, 1, file: file, line: line)
    }

    private func assertNoCloseButton(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.buttons["关闭"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["Close"].exists, file: file, line: line)
    }

    private func backToMine(_ app: XCUIApplication, title: String) {
        let back = app.navigationBars[title].buttons["我的"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }

    private func nativeBackButton(in app: XCUIApplication, title: String, destination: String) -> XCUIElement {
        app.navigationBars[title].buttons.matching(NSPredicate(
            format: "label IN %@",
            [destination, "返回", "Back", "侧边栏", "Sidebar"]
        )).firstMatch
    }

    private func switchAwayAndBack(_ app: XCUIApplication) {
        let otherTab = app.buttons["验收页"].firstMatch
        XCTAssertTrue(otherTab.waitForExistence(timeout: 5))
        XCTAssertTrue(otherTab.isHittable)
        otherTab.tap()
        XCTAssertTrue(app.staticTexts["mine.fixture.other"].waitForExistence(timeout: 5))
        let mineTab = app.buttons["我的"].firstMatch
        XCTAssertTrue(mineTab.waitForExistence(timeout: 5))
        mineTab.tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

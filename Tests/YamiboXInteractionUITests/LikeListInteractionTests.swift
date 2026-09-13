import XCTest
import UIKit

@MainActor
final class LikeListInteractionTests: XCTestCase {
    func testIPadWorkCategoriesUseTopPickerAndPreserveNativeBackNavigation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires iPad layout")
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = originalOrientation }

        let app = launch()
        let novel = app.buttons["like.work.novel.100"]
        XCTAssertTrue(novel.waitForExistence(timeout: 10))
        let picker = app.segmentedControls["likes.category.picker"]
        XCTAssertTrue(picker.exists)
        XCTAssertFalse(app.descendants(matching: .any)["library.category.sidebar"].exists)

        let novelCategory = picker.buttons["小说"]
        let mangaCategory = picker.buttons["漫画"]
        XCTAssertTrue(novelCategory.waitForExistence(timeout: 3))
        novelCategory.tap()
        XCTAssertTrue(app.navigationBars["喜欢"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["like.work.manga.测试漫画"].exists)
        novel.tap()
        XCTAssertTrue(app.buttons["like.item.fixture-text"].waitForExistence(timeout: 3))

        app.navigationBars.buttons["喜欢"].firstMatch.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        mangaCategory.tap()
        XCTAssertTrue(app.buttons["like.work.manga.测试漫画"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["喜欢"].exists)
        XCTAssertFalse(app.buttons["like.item.fixture-text"].exists)
        XCTAssertTrue(picker.exists)

        app.buttons["选择"].tap()
        app.buttons["全选"].tap()
        XCTAssertTrue(app.buttons["删除 1 项"].waitForExistence(timeout: 3))
        XCTAssertFalse(novelCategory.isEnabled)
        app.buttons["完成"].tap()
        XCTAssertTrue(novelCategory.isEnabled)
        novelCategory.tap()
        XCTAssertTrue(novel.waitForExistence(timeout: 3))
        attach(app, "Likes iPad top category picker")
    }

    func testWorkSelectionAndDeletionOnlyAffectFilteredWorks() {
        let app = launch()
        let novel = app.buttons["like.work.novel.100"]
        XCTAssertTrue(novel.waitForExistence(timeout: 10))
        app.buttons["选择"].tap()
        app.buttons["全选"].tap()
        XCTAssertTrue(app.buttons["删除 3 项"].waitForExistence(timeout: 3))
        app.segmentedControls.buttons["漫画"].tap()
        XCTAssertTrue(app.buttons["删除 0 项"].waitForExistence(timeout: 3))
        app.buttons["全选"].tap()
        app.buttons["删除 1 项"].tap()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["还没有喜欢的漫画"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["全部"].tap()
        XCTAssertTrue(novel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["like.work.novel.200"].exists)
        XCTAssertFalse(app.buttons["like.work.manga.测试漫画"].exists)
    }

    func testWorkSearchIntersectsKindAndClearsSelection() {
        let app = launch()
        let novel = app.buttons["like.work.novel.100"]
        XCTAssertTrue(novel.waitForExistence(timeout: 10))
        app.segmentedControls.buttons["小说"].tap()
        app.buttons["选择"].tap()
        novel.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("长夜")
        XCTAssertTrue(app.buttons["删除 0 项"].waitForExistence(timeout: 3))
        XCTAssertTrue(novel.exists)
        XCTAssertFalse(app.buttons["like.work.novel.200"].exists)
        XCTAssertFalse(app.buttons["like.work.manga.测试漫画"].exists)
        search.typeText("无结果")
        XCTAssertFalse(novel.waitForExistence(timeout: 1))
    }

    func testMangaItemsHaveNoContentFilterAndKeepSavedSource() {
        let app = launch(["LIKES_FIXTURE_ENTRY": "manga"])
        let image = app.buttons["like.item.fixture-manga"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertEqual(app.segmentedControls.count, 0)
        XCTAssertFalse(app.buttons["likes.contentFilter"].exists)
        XCTAssertTrue(image.label.contains("第十二话"), image.debugDescription)
    }

    func testWorksAndNovelFiltersKeepSavedChapterSources() {
        let app = launch()
        let novel = app.buttons["like.work.novel.100"]
        let manga = app.buttons["like.work.manga.测试漫画"]
        XCTAssertTrue(novel.waitForExistence(timeout: 10))
        attach(app, "Likes compact work rows and visible navigation title")
        app.segmentedControls.buttons["漫画"].tap()
        XCTAssertTrue(manga.waitForExistence(timeout: 3))
        XCTAssertFalse(novel.exists)
        app.segmentedControls.buttons["小说"].tap()
        XCTAssertTrue(novel.waitForExistence(timeout: 3))
        XCTAssertFalse(manga.exists)
        novel.tap()
        let text = app.buttons["like.item.fixture-text"]
        let image = app.buttons["like.item.fixture-image"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue(text.label.contains("第一章 初次相遇"), text.debugDescription)
        app.segmentedControls.buttons["图片"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        XCTAssertFalse(text.exists)
        app.segmentedControls.buttons["文本"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertFalse(image.exists)
        attach(app, "Likes text rows with saved and missing sources")
        text.tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 3))
        attach(app, "Text excerpt detail with saved source")
    }

    func testChangingFilterClearsSelectionAndDeleteOnlyAffectsVisibleItems() {
        let app = launch(["LIKES_FIXTURE_ENTRY": "novel"])
        let text = app.buttons["like.item.fixture-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        app.buttons["选择"].tap()
        text.tap()
        XCTAssertTrue(app.buttons["删除 1 项"].waitForExistence(timeout: 3))
        app.segmentedControls.buttons["图片"].tap()
        let deleteNothing = app.buttons["删除 0 项"]
        XCTAssertTrue(deleteNothing.waitForExistence(timeout: 3))
        XCTAssertFalse(deleteNothing.isEnabled)
        app.buttons["全选"].tap()
        app.buttons["删除 1 项"].tap()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["还没有图片摘录"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["全部"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["like.item.fixture-legacy"].exists)
        XCTAssertFalse(app.buttons["like.item.fixture-image"].exists)
    }

    func testReaderUsesMenuAndOpensAnchorWithoutDetailSheet() {
        let app = launch(["LIKES_FIXTURE_ENTRY": "reader"])
        let filter = app.buttons["likes.contentFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertEqual(app.segmentedControls.count, 1)
        let text = app.buttons["like.item.fixture-text"]
        let image = app.buttons["like.item.fixture-image"]
        XCTAssertEqual(image.staticTexts["like.chapterTitle"].frame.minX,
                       text.staticTexts["like.chapterTitle"].frame.minX, accuracy: 1)
        XCTAssertEqual(image.staticTexts["like.createdAt"].frame.maxX,
                       text.staticTexts["like.createdAt"].frame.maxX, accuracy: 1)
        attach(app, "Reader likes compact filter")
        filter.tap()
        app.buttons["文本"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["like.item.fixture-image"].exists)
        text.tap()
        XCTAssertTrue(app.staticTexts["likes-fixture-opened"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["更多"].exists)
    }

    func testSearchIntersectsFilterAndClearsSelectedItems() {
        let app = launch(["LIKES_FIXTURE_ENTRY": "novel"])
        let text = app.buttons["like.item.fixture-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        app.segmentedControls.buttons["文本"].tap()
        app.buttons["选择"].tap()
        text.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("第一章")
        XCTAssertTrue(app.buttons["删除 0 项"].waitForExistence(timeout: 3))
        XCTAssertTrue(text.exists)
        XCTAssertFalse(app.buttons["like.item.fixture-legacy"].exists)
        search.typeText("无结果")
        XCTAssertFalse(text.waitForExistence(timeout: 1))
        attach(app, "Filtered empty search")
    }

    func testDarkLargeTextAndImageFailureKeepMetadataBelowContent() {
        let app = launch(["LIKES_FIXTURE_ENTRY": "novel", "LIKES_FIXTURE_DARK": "1", "LIKES_FIXTURE_LARGE_TEXT": "1", "LIKES_FIXTURE_IMAGE_FAILURE": "1"])
        XCTAssertTrue(app.buttons["like.item.fixture-text"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["文本"].tap()
        attach(app, "Likes dark accessibility text")
        app.segmentedControls.buttons["图片"].tap()
        let image = app.buttons["like.item.fixture-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        XCTAssertTrue(image.label.contains("第二章"), image.debugDescription)
        XCTAssertFalse(app.staticTexts["章节信息暂缺"].exists)
        attach(app, "Likes image failure and long source")
    }

    private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LIKES_FIXTURE"] = "1"
        app.launchEnvironment.merge(environment) { _, value in value }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

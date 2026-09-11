import XCTest

@MainActor
final class ChapterCommentFilterInteractionTests: XCTestCase {
    func testEditPreviewValidationAndPersistedRule() {
        let app = launch()
        app.buttons["chapter-comment-rules-discussions"].tap()
        app.buttons["chapter-comment-add-rule"].tap()
        let pattern = app.textViews["chapter-comment-pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 5))
        let save = app.buttons["chapter-comment-save-rule"]
        XCTAssertFalse(save.isEnabled)
        pattern.tap()
        pattern.typeText("[")
        XCTAssertFalse(save.isEnabled)
        pattern.typeText(XCUIKeyboardKey.delete.rawValue + "(?i)hello")
        let sample = app.textViews["chapter-comment-test-text"]
        sample.tap()
        sample.typeText("HELLO")
        XCTAssertTrue(app.staticTexts["匹配"].waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(app.staticTexts["(?i)hello"].waitForExistence(timeout: 3))

        app.buttons["chapter-comment-add-rule"].tap()
        pattern.tap()
        pattern.typeText("(?i)hello")
        XCTAssertTrue(app.staticTexts["此组已存在相同规则"].waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled)
        app.buttons["取消"].tap()
        app.terminate()
        app.launchEnvironment["CHAPTER_COMMENT_FILTER_KEEP_SETTINGS"] = "1"
        app.launch()
        app.buttons["chapter-comment-rules-discussions"].tap()
        XCTAssertTrue(app.staticTexts["(?i)hello"].waitForExistence(timeout: 3))
    }

    func testOwnContentAndCacheRestoreWhenDisabled() {
        let app = launch()
        app.buttons["filter-fixture-open-comments"].tap()
        XCTAssertTrue(app.staticTexts["我的评分"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["默认评分"].exists)
        XCTAssertTrue(app.staticTexts["点评读者"].exists)
        app.buttons["完成"].tap()
        app.buttons["chapter-comment-rules-ratings"].tap()
        let toggle = app.switches["chapter-comment-filter-enabled"]
        let control = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        control.tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 3), .completed, toggle.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["chapter-comment-rules-ratings"].label.contains("已关闭"))
        app.buttons["filter-fixture-open-comments"].tap()
        XCTAssertTrue(app.staticTexts["默认评分"].waitForExistence(timeout: 5))
    }

    func testAllHiddenCanStillLoadNextPage() {
        let app = launch(["CHAPTER_COMMENT_FILTER_ALL_HIDDEN": "1"])
        app.buttons["filter-fixture-open-comments"].tap()
        XCTAssertTrue(app.staticTexts["暂无可见评论"].waitForExistence(timeout: 5))
        let next = app.buttons["加载更多..."]
        XCTAssertTrue(next.exists)
        next.tap()
        XCTAssertTrue(app.staticTexts["下一页读者"].waitForExistence(timeout: 5))
    }

    func testSaveFailureKeepsDraftAndAllowsRetry() {
        let app = launch(["CHAPTER_COMMENT_FILTER_FAIL_SAVE": "1"])
        app.buttons["chapter-comment-rules-discussions"].tap()
        app.buttons["chapter-comment-add-rule"].tap()
        let pattern = app.textViews["chapter-comment-pattern"]
        pattern.tap()
        pattern.typeText("draft")
        let save = app.buttons["chapter-comment-save-rule"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(app.staticTexts["测试存储不可用"].waitForExistence(timeout: 5))
        XCTAssertEqual(pattern.value as? String, "draft")
        XCTAssertTrue(save.isEnabled)
    }

    private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CHAPTER_COMMENT_FILTER_FIXTURE"] = "1"
        app.launchEnvironment.merge(environment) { _, value in value }
        app.launch()
        XCTAssertTrue(app.buttons["chapter-comment-rules-ratings"].waitForExistence(timeout: 5))
        return app
    }
}

import XCTest

@MainActor
final class CreditLogInteractionTests: XCTestCase {
    func testAllThreeOwnStatisticsOpenAllRecordsAndOtherProfileRemainsReadOnly() {
        let app = launch()
        defer { app.terminate() }
        for identifier in ["credit-log-total-points", "credit-log-points", "credit-log-partner"] {
            let entry = app.buttons[identifier]
            XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
            entry.tap()
            XCTAssertTrue(app.navigationBars["积分记录"].waitForExistence(timeout: 5))
            let filter = app.segmentedControls["credit-log-filter"]
            XCTAssertTrue(filter.waitForExistence(timeout: 5))
            XCTAssertTrue(filter.buttons["全部"].isSelected)
            filter.buttons["收入"].tap()
            XCTAssertTrue(app.staticTexts["帖子被评分"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["购买附件"].exists)
            filter.buttons["支出"].tap()
            XCTAssertTrue(app.staticTexts["购买附件"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["帖子被评分"].exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.terminate()
        app.launchEnvironment["CREDIT_LOG_OTHER_PROFILE"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["测试用户"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["credit-log-total-points"].exists)
        XCTAssertFalse(app.buttons["credit-log-points"].exists)
        XCTAssertFalse(app.buttons["credit-log-partner"].exists)
    }

    func testDescriptionLinkReturnsToRecordsAndPageNavigationScrollsToTop() {
        let app = launch()
        defer { app.terminate() }
        openRecords(app)
        let title = "Yamibo X：iOS端的百合会App，提供原生阅读体验与收藏管理"
        let link = app.links[title]
        XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
        link.tap()
        let opened = app.staticTexts["credit-fixture-opened-url"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
        XCTAssertTrue(opened.label.contains("pid=456"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let next = app.buttons["下一页"]
        scrollTo(next, in: app)
        next.tap()
        XCTAssertTrue(app.staticTexts["第2页记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第2页记录"].isHittable)
        attach(app, name: "credit-log-page-two")
        let previous = app.buttons["上一页"]
        scrollTo(previous, in: app)
        XCTAssertFalse(next.isEnabled)
        previous.tap()
        XCTAssertTrue(app.staticTexts["账号 1"].waitForExistence(timeout: 5))
    }

    func testFailedPageRetainsRecordsAndRetryLoadsTarget() {
        let app = launch(environment: ["CREDIT_LOG_FAIL_PAGE": "1"])
        defer { app.terminate() }
        openRecords(app)
        let next = app.buttons["下一页"]
        scrollTo(next, in: app)
        next.tap()
        let retry = app.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(app.staticTexts["账号 1"].exists)
        XCTAssertFalse(app.staticTexts["第2页记录"].exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["第2页记录"].waitForExistence(timeout: 5))
    }

    func testAccountChangeRebuildsPageAndExpenseEmptyState() {
        let app = launch(environment: ["CREDIT_LOG_EMPTY_EXPENSE": "1"])
        defer { app.terminate() }
        openRecords(app)
        let filter = app.segmentedControls["credit-log-filter"]
        filter.buttons["支出"].tap()
        XCTAssertTrue(app.staticTexts["暂无支出记录"].waitForExistence(timeout: 5))
        app.buttons["credit-fixture-switch-account"].tap()
        XCTAssertTrue(app.staticTexts["账号 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(filter.buttons["全部"].isSelected)
        XCTAssertFalse(app.staticTexts["账号 1"].exists)
    }

    func testDarkLargeTextLayout() {
        let app = launch(environment: ["CREDIT_LOG_DARK": "1", "CREDIT_LOG_THEME": "teal"], largeText: true)
        defer { app.terminate() }
        openRecords(app)
        XCTAssertTrue(app.segmentedControls["credit-log-filter"].buttons["收入"].isHittable)
        attach(app, name: "credit-log-dark-large-text")
    }

    private func launch(environment: [String: String] = [:], largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CREDIT_LOG_FIXTURE"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func openRecords(_ app: XCUIApplication) {
        let entry = app.buttons["credit-log-points"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.staticTexts["账号 1"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, name: "credit-log-all")
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

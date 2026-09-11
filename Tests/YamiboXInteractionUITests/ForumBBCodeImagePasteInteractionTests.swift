import XCTest

@MainActor
final class ForumBBCodeImagePasteInteractionTests: XCTestCase {
    func testPastedImageRequiresConfirmationAndStillWorksAfterFullscreen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["BBCODE_PASTE_FIXTURE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let paste = app.buttons["bbcode-paste-fixture-image"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        paste.tap()
        let confirm = app.sheets.buttons["上传"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["bbcode-paste-fixture-count"].label, "uploads=0")
        let cancel = app.sheets.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        if cancel.exists { cancel.tap() }
        else {
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.exists, app.debugDescription)
            dismissRegion.tap()
        }
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["bbcode-paste-fixture-count"].label, "uploads=0")
        app.buttons["全屏编辑"].tap()
        XCTAssertTrue(app.navigationBars.buttons["完成"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["bbcode-paste-fixture-count"].label, "uploads=0")
        confirm.tap()
        let uploaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'uploads=1'"), object: app.staticTexts["bbcode-paste-fixture-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [uploaded], timeout: 5), .completed)
        let source = app.switches["native-composer-plain-text"].firstMatch
        let inner = source.descendants(matching: .switch).firstMatch
        (inner.exists ? inner : source).tap()
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Before image[attachimg]999002[/attachimg]"), object: app.textViews.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "bbcode-paste-confirmed-source"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

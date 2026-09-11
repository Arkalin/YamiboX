import XCTest

@MainActor
final class ForumWebInteractionTests: XCTestCase {
    func testOriginalLayoutJavaScriptPOSTAndNativeNewWindow() {
        let app = launch()
        defer { app.terminate() }
        let web = app.webViews.firstMatch
        let left = web.staticTexts["CSS Left"]
        let right = web.staticTexts["CSS Right"]
        XCTAssertTrue(left.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(right.exists)
        XCTAssertLessThan(left.frame.minX, right.frame.minX)
        XCTAssertEqual(left.frame.minY, right.frame.minY, accuracy: 2)
        web.buttons["Run JavaScript"].tap()
        XCTAssertTrue(web.buttons["JavaScript works"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "original-web-layout-and-javascript"
        attachment.lifetime = .keepAlways
        add(attachment)
        web.buttons["Submit POST"].tap()
        XCTAssertTrue(web.staticTexts["POST stayed in WebView"].waitForExistence(timeout: 5))
        let link = web.links["Native new window"]
        if !link.isHittable { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.staticTexts["Native handoffs: 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Native handoffs: 2"].exists)
    }

    func testHTTPRedirectHandsOffToNativeOnce() {
        let app = launch()
        defer { app.terminate() }
        let link = app.webViews.links["Native redirect"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), app.debugDescription)
        if !link.isHittable { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.staticTexts["Native handoffs: 1"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Native handoffs: 2"].exists)
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_WEB_FIXTURE"] = "1"
        app.launch()
        return app
    }
}

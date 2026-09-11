import XCTest

@MainActor
final class ForumWebInteractionTests: XCTestCase {
    func testCancelledSwipeBackKeepsBrowserTitleCentered() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_WEB_NAVIGATION_FIXTURE"] = "1"
        app.launch()
        defer { app.terminate() }

        let open = app.buttons["Open WebView"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.webViews.staticTexts["CSS Left"].waitForExistence(timeout: 15))
        let title = app.descendants(matching: .any)["forum-browser-navigation-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let originalFrame = title.frame
        XCTAssertEqual(originalFrame.midX, app.navigationBars.firstMatch.frame.midX, accuracy: 1)

        for _ in 0..<3 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
            XCTAssertTrue(app.buttons["forum-browser-refresh"].exists, "The partial swipe must be cancelled")
            let restored = NSPredicate { _, _ in
                abs(title.frame.midX - originalFrame.midX) < 2
                    && abs(title.frame.width - originalFrame.width) < 2
            }
            let settled = expectation(for: restored, evaluatedWith: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                           "Title moved from \(originalFrame) to \(title.frame)")
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "web-title-after-cancelled-back-swipes"
        attachment.lifetime = .keepAlways
        add(attachment)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.frame.midX, originalFrame.midX, accuracy: 2)
    }

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

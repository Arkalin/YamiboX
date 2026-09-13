import XCTest

@MainActor
final class WebDAVContentInteractionTests: XCTestCase {
    func testContentSelectionPersistsAndDisablesContinueWhenAllOff() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "WEBDAV_CONTENT_FIXTURE": "1",
            "WEBDAV_CONTENT_FIXTURE_ID": UUID().uuidString
        ]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        openWebDAV(app)
        let entry = app.buttons["webdav.syncContent"]
        let automatic = app.switches["自动同步数据"].firstMatch
        XCTAssertTrue(automatic.exists)
        XCTAssertGreaterThan(entry.frame.minY, automatic.frame.minY)
        XCTAssertTrue(app.buttons["继续"].isEnabled)
        capture(app, "webdav-settings")
        entry.tap()

        let ids = ["favoriteLibrary", "likeLibrary", "bookmarkLibrary", "readingProgress",
                   "contentCovers", "appSettings", "mangaDirectories", "browsingHistory"]
        for id in ids {
            let toggle = app.switches["webdav.content.\(id)"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), id)
            XCTAssertEqual(toggle.value as? String, "1", id)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            waitForValue("0", of: toggle)
        }
        capture(app, "webdav-content-all-off")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["继续"].isEnabled)

        // A relaunch rebuilds the view model and reloads the isolated persisted suite.
        app.terminate()
        app.launch()
        openWebDAV(app)
        XCTAssertFalse(app.buttons["继续"].isEnabled)
        app.buttons["webdav.syncContent"].tap()
        for id in ids {
            XCTAssertEqual(app.switches["webdav.content.\(id)"].firstMatch.value as? String, "0", id)
        }
        let history = app.switches["webdav.content.browsingHistory"].firstMatch
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitForValue("1", of: history)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["继续"].isEnabled)
        // Do not tap Continue: this fixture deliberately never contacts a WebDAV server.
    }

    private func waitForValue(_ value: String, of element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func openWebDAV(_ app: XCUIApplication) {
        let entry = app.buttons.matching(NSPredicate(format: "label == %@", "WebDAV 同步")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.buttons["webdav.syncContent"].waitForExistence(timeout: 5))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

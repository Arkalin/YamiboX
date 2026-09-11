import XCTest

@MainActor
final class ImageBrowserInteractionTests: XCTestCase {
    func testHorizontalAndDiagonalSwipesChangeUnzoomedPages() {
        continueAfterFailure = false
        for presentation in ["fade", "zoom"] {
            XCTContext.runActivity(named: presentation) { _ in
                let app = launchGallery(presentation: presentation)
                defer { app.terminate() }

                for velocity in [XCUIGestureVelocity.slow, .fast] {
                    swipe(app, from: 0.8, to: 0.2, verticalOffset: 0, velocity: velocity)
                    expectPage(3, in: app)
                    swipe(app, from: 0.2, to: 0.8, verticalOffset: 0.06, velocity: velocity)
                    expectPage(2, in: app)
                    swipe(app, from: 0.2, to: 0.8, verticalOffset: -0.06, velocity: velocity)
                    expectPage(1, in: app)
                    swipe(app, from: 0.8, to: 0.2, verticalOffset: 0.06, velocity: velocity)
                    expectPage(2, in: app)
                }

                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "image-browser-\(presentation)-after-paging"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testPagingSurvivesCancelledDismissAndZoomReset() {
        continueAfterFailure = false
        for presentation in ["fade", "zoom"] {
            XCTContext.runActivity(named: presentation) { _ in
                let app = launchGallery(presentation: presentation)
                defer { app.terminate() }

                let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                center.press(forDuration: 0.01, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 35)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
                expectPage(2, in: app)
                swipe(app, from: 0.8, to: 0.2, verticalOffset: 0, velocity: .fast)
                expectPage(3, in: app)
                swipe(app, from: 0.2, to: 0.8, verticalOffset: 0, velocity: .fast)
                expectPage(2, in: app)

                center.doubleTap()
                swipe(app, from: 0.65, to: 0.35, verticalOffset: 0, velocity: .slow)
                expectPage(2, in: app)
                center.doubleTap()
                swipe(app, from: 0.8, to: 0.2, verticalOffset: 0, velocity: .fast)
                expectPage(3, in: app)
                dismissGallery(app)
            }
        }
    }

    func testSingleImageStillDismissesWithoutAPager() {
        continueAfterFailure = false
        let app = launchGallery(presentation: "fade", single: true)
        defer { app.terminate() }
        dismissGallery(app)
    }

    private func launchGallery(presentation: String, single: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["IMAGE_BROWSER_FIXTURE"] = "1"
        app.launchEnvironment["IMAGE_BROWSER_PRESENTATION"] = presentation
        app.launchEnvironment["IMAGE_BROWSER_SINGLE"] = single ? "1" : "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let open = app.buttons["Open gallery"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        expectPage(2, in: app)
        return app
    }

    private func expectPage(_ page: Int, in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Image \(page)"].waitForExistence(timeout: 3), app.debugDescription)
    }

    private func dismissGallery(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"),
            object: app.buttons["Open gallery"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func swipe(_ app: XCUIApplication, from: CGFloat, to: CGFloat,
                       verticalOffset: CGFloat, velocity: XCUIGestureVelocity) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5 + verticalOffset))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
    }
}

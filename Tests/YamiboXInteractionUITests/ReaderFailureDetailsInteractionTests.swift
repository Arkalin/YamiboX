import UIKit
import XCTest

@MainActor
final class ReaderFailureDetailsInteractionTests: XCTestCase {
    func testHostedFailureDetailsShowDiagnosticAndRepeatedlyDismissWithoutClosingReader() throws {
        let app = try launchFixture()
        defer { app.terminate() }

        for index in 0..<2 {
            openDetails(app, expectedRequest: "page-1.png")
            attach(app, name: "reader-failure-details-open-\(index)")
            app.buttons["load-failure-close"].tap()
            XCTAssertTrue(app.textViews["load-failure-text"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons["failure-fixture-close-reader"].isHittable)
            XCTAssertFalse(app.buttons["failure-fixture-open"].isHittable)
        }

        app.buttons["failure-fixture-close-reader"].tap()
        XCTAssertTrue(app.buttons["failure-fixture-open"].waitForExistence(timeout: 5))
    }

    func testRetryRemovesOldHostedDetailsAndNextFailureOpensFreshDiagnostic() throws {
        let app = try launchFixture()
        defer { app.terminate() }

        app.buttons["failure-fixture-delayed-retry"].tap()
        openDetails(app, expectedRequest: "page-1.png")
        XCTAssertTrue(app.textViews["load-failure-text"].waitForNonExistence(timeout: 10),
            "Replacing the failed content with loading must dismiss its details sheet")
        XCTAssertTrue(app.buttons["failure-fixture-close-reader"].isHittable)
        XCTAssertEqual(app.staticTexts["failure-fixture-status"].label, "Loading retry")
        attach(app, name: "reader-failure-retry-dismissed-details")

        app.buttons["failure-fixture-fail-again"].tap()
        openDetails(app, expectedRequest: "page-2.png")
        let diagnostic = app.textViews["load-failure-text"].value as? String ?? ""
        XCTAssertFalse(diagnostic.contains("page-1.png"))
        app.buttons["load-failure-close"].tap()
        XCTAssertTrue(app.textViews["load-failure-text"].waitForNonExistence(timeout: 5))

        let retry = app.buttons.matching(NSPredicate(format: "label IN %@", ["重试", "Retry"])).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(app.buttons["load-failure-details"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["failure-fixture-status"].label, "Loading retry")
    }

    private func launchFixture() throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Exercises an iPad manga spread host")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["READER_FAILURE_DETAILS_FIXTURE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let open = app.buttons["failure-fixture-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["load-failure-details"].waitForExistence(timeout: 5))
        return app
    }

    private func openDetails(_ app: XCUIApplication, expectedRequest: String) {
        let button = app.buttons["load-failure-details"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let text = app.textViews["load-failure-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Expected diagnostic text, not a disabled-presentation placeholder")
        let diagnostic = text.value as? String ?? ""
        XCTAssertTrue(diagnostic.contains("image-fixture.invalid"), diagnostic)
        XCTAssertTrue(diagnostic.contains(expectedRequest), diagnostic)
        XCTAssertTrue(diagnostic.contains("-1001"), diagnostic)
        XCTAssertTrue(app.buttons["load-failure-close"].isHittable)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

@MainActor
final class RequiredFeatureDependenciesInteractionTests: XCTestCase {
    func testHistoryUsesCanonicalWorkflowAndDoesNotResurrectDeletedRows() {
        let app = launch("history")
        defer { app.terminate() }
        tap("record", in: app)
        expect("required-history", contains: "home=1; history=1; same=true", in: app)
        tap("mode", in: app)
        expect("required-history", contains: "home=1; history=1; same=true; route=manga", in: app)
        tap("delete", in: app)
        expect("required-history", contains: "home=0; history=0; same=true; deleted", in: app)
    }

    func testPreviewLoadsContentWithoutWritingHistoryOrProgress() {
        let app = launch("history")
        defer { app.terminate() }
        tap("preview", in: app)
        expect("required-history", contains: "home=0; history=0; same=true; previewLoaded=true; previewProgress=false", in: app)
    }

    func testUnreadRefreshAndAccountChangeDiscardOldResponse() {
        let app = launch("messages")
        defer { app.terminate() }
        tap("guest", in: app)
        expect("required-messages", contains: "unread=0; requests=0; guest", in: app)
        tap("signin", in: app)
        expect("required-messages", contains: "unread=3;", in: app)
        tap("read", in: app)
        expect("required-messages", contains: "unread=0;", in: app)
        tap("delay", in: app)
        expect("required-messages", contains: "pending", in: app)
        tap("switch", in: app)
        expect("required-messages", contains: "unread=1;", in: app)
        expect("required-messages", contains: "switched", in: app)
    }

    func testDraftRestorationFailedSubmissionAndAccountIsolation() {
        let app = launch("draft")
        defer { app.terminate() }
        tap("editor", in: app)
        expect("required-draft", contains: "active=true", in: app)
        let text = app.textFields["required-draft-text"]
        text.tap()
        text.typeText("Durable draft")
        app.navigationBars.firstMatch.tap()
        tap("save", in: app)
        expect("required-draft", contains: "saved=true", in: app)
        tap("reopen", in: app)
        XCTAssertEqual(text.value as? String, "Durable draft")
        expect("required-draft", contains: "attachments=1; resource=persisted attachment; reopened", in: app)
        tap("fail", in: app)
        XCTAssertEqual(text.value as? String, "Durable draft")
        expect("required-draft", contains: "attachments=1; resource=persisted attachment; failed=true", in: app)
        tap("switch-draft", in: app)
        expect("required-draft", contains: "active=true; drafts=0; attachments=0;", in: app)
        XCTAssertNotEqual(text.value as? String, "Durable draft")
    }

    func testGuestAndNonPostFormsKeepDraftCapabilityInactive() {
        let app = launch("draft")
        defer { app.terminate() }
        tap("guest-editor", in: app)
        expect("required-draft", contains: "active=false; drafts=0;", in: app)
        tap("standard", in: app)
        expect("required-draft", contains: "active=false; drafts=0;", in: app)
        expect("required-draft", contains: "standard", in: app)
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["REQUIRED_FEATURE_FIXTURE"] = scenario
        app.launch()
        XCTAssertTrue(app.staticTexts["required-ready"].waitForExistence(timeout: 15))
        return app
    }

    private func tap(_ id: String, in app: XCUIApplication) {
        let button = app.buttons["required-\(id)"]
        if !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'ready'"), object: app.staticTexts["required-ready"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        XCTAssertEqual(app.staticTexts["required-error"].label, "")
    }

    private func expect(_ id: String, contains value: String, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", value), object: app.staticTexts[id])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, app.debugDescription)
    }
}

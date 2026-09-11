import XCTest

@MainActor
final class ForumComposerOptionsInteractionTests: XCTestCase {
    func testOptionsPreserveSignatureAndPrepareWithoutSubmitting() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_SEND_CRASH_FIXTURE"] = "1"
        app.launchEnvironment["FORUM_COMPOSER_OPTIONS_FIXTURE"] = "1"
        app.launchEnvironment["FORUM_SEND_ACTION"] = "newthread"
        app.launchEnvironment["FORUM_SEND_FIRST_POST"] = "1"
        app.launchEnvironment["FORUM_SEND_INITIAL_SOURCE"] = "[b]Offline composer body[/b]"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        let open = app.buttons["forum-feedback-open-editor"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))

        let options = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                       "native-composer-options", "更多选项")).firstMatch
        reveal(options, in: app)
        options.tap()
        let signature = app.switches["使用签名"]
        XCTAssertTrue(signature.waitForExistence(timeout: 5), app.debugDescription)
        reveal(signature, in: app)
        let innerSwitch = signature.descendants(matching: .switch).firstMatch
        let toggle = innerSwitch.exists ? innerSwitch : signature
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        expectDiagnostics("signature=false", in: app)
        let sourceMode = app.switches.matching(NSPredicate(format: "identifier == %@ OR label == %@", "native-composer-plain-text", "源码")).firstMatch
        XCTAssertEqual(sourceMode.value as? String, "0")

        reveal(options, in: app)
        options.tap()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: signature)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        options.tap()
        XCTAssertTrue(signature.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        attach(app, name: "composer-options-signature-preserved")

        let send = app.navigationBars.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-form-submit-")).firstMatch
        XCTAssertTrue(send.isHittable)
        send.tap()
        XCTAssertTrue(app.sheets.buttons["Send Reply"].waitForExistence(timeout: 5))
        expectDiagnostics("pending=true", in: app)
        expectDiagnostics("preparedSignature=false", in: app)
        expectDiagnostics("count=0", in: app)
        attach(app, name: "composer-options-prepared-without-submitting")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 4 where !element.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func expectDiagnostics(_ text: String, in app: XCUIApplication) {
        let diagnostics = app.staticTexts["forum-send-diagnostics"].firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: diagnostics)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, diagnostics.label)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

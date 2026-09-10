import XCTest

@MainActor
final class ForumSendCrashInteractionTests: XCTestCase {
    func testTopSendFromFocusedEditorPresentsAndConfirmsOfflineSubmission() throws {
        continueAfterFailure = false
        for action in ["reply", "edit"] {
            for codeMode in [false, true] {
                try exercise(action: action, codeMode: codeMode)
            }
        }
    }

    private func exercise(action: String, codeMode: Bool) throws {
        let fails = codeMode
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_SEND_CRASH_FIXTURE"] = "1"
        app.launchEnvironment["FORUM_SEND_ACTION"] = action
        app.launchEnvironment["FORUM_SEND_FAIL"] = fails ? "1" : "0"
        app.launchEnvironment["FORUM_SEND_INITIAL_SOURCE"] = "[b][i]中文🙂[/i][/b] [url=https://bbs.yamibo.com/]链接[/url]\n[quote]引用[/quote]"
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["forum-feedback-open-editor"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["native-form-field-subject"].exists)
        XCTAssertTrue((editor.value as? String)?.contains("中文") == true)
        XCTAssertFalse((editor.value as? String)?.contains("[b]") == true)
        if codeMode {
            let wrapper = app.switches.firstMatch
            XCTAssertTrue(wrapper.waitForExistence(timeout: 5))
            let toggle = wrapper.descendants(matching: .switch).firstMatch
            XCTAssertTrue(toggle.exists, app.debugDescription)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "offline-composer-switch-hierarchy-\(action)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            toggle.tap()
            let modeChanged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "[b]"), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [modeChanged], timeout: 3), .completed)
        }
        editor.tap()
        editor.typeText("Offline reply text")
        let draft = editor.value as? String
        let send = app.navigationBars.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native-form-submit-")).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isHittable)
        send.tap()
        let dialogAction = app.sheets.buttons["Send Reply"].firstMatch
        XCTAssertTrue(dialogAction.waitForExistence(timeout: 8), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "offline-send-confirmation-\(action)-\(codeMode ? "code" : "visual")"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        dialogAction.tap()
        if fails {
            let failureToast = app.buttons["toast-failure-details"]
            XCTAssertTrue(failureToast.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(failureToast.label.contains("Offline submission failed"))
            attachScreenshot(app, name: "offline-feedback-failure-\(action)-code")
            XCTAssertTrue(editor.exists)
            XCTAssertFalse(app.staticTexts["forum-feedback-previous-page"].exists)
            XCTAssertTrue(app.staticTexts["forum-send-diagnostics"].label.contains("count=1"))
            XCTAssertTrue(app.staticTexts["forum-send-diagnostics"].label.contains("success=false"))
            XCTAssertEqual(editor.value as? String, draft)
            editor.tap()
            editor.typeText(" retry")
            XCTAssertNotEqual(editor.value as? String, draft)
            send.tap()
            XCTAssertTrue(dialogAction.waitForExistence(timeout: 8))
            dialogAction.tap()
        }
        let successToast = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Offline submission captured")).firstMatch
        XCTAssertTrue(successToast.waitForExistence(timeout: 8), app.debugDescription)
        let editorDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [editorDismissed], timeout: 5), .completed, app.debugDescription)
        attachScreenshot(app, name: "offline-feedback-returned-\(action)-\(codeMode ? "code-retry" : "visual")")
        XCTAssertTrue(app.staticTexts["forum-feedback-previous-page"].exists)
        XCTAssertFalse(editor.exists)
        XCTAssertFalse(app.staticTexts["操作结果"].exists)
        XCTAssertTrue(app.staticTexts["forum-send-diagnostics"].label.contains(fails ? "count=2" : "count=1"))
        XCTAssertTrue(app.staticTexts["forum-send-diagnostics"].label.contains("success=true"))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testFirstPostEditKeepsEditableSubject() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_SEND_CRASH_FIXTURE"] = "1"
        app.launchEnvironment["FORUM_SEND_ACTION"] = "edit"
        app.launchEnvironment["FORUM_SEND_FIRST_POST"] = "1"
        app.launchEnvironment["FORUM_SEND_INITIAL_SOURCE"] = "[b]Original body[/b]"
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["forum-feedback-open-editor"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let subject = app.textFields["native-form-field-subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(subject.value as? String, "Offline Subject")
        subject.tap()
        subject.typeText(" edited")
        XCTAssertTrue((subject.value as? String)?.contains(" edited") == true)
        attachScreenshot(app, name: "offline-first-post-title-editable")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let result = XCTAttachment(screenshot: app.screenshot())
        result.name = name
        result.lifetime = .keepAlways
        add(result)
    }
}

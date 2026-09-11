import XCTest

@MainActor
final class ForumBBCodeEditorInteractionTests: XCTestCase {
    func testBlockPanelsCancelChangesAndModesPreserveOfflineSource() throws {
        continueAfterFailure = false
        let source = """
        [b]Readable BBCode preview[/b]
        [table][tr][td]Alpha[/td][td]Beta[/td][/tr][tr][td]Gamma[/td][td]Delta[/td][/tr][/table]
        [hide]Hidden preview remains readable[/hide]
        """
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_SEND_CRASH_FIXTURE"] = "1"
        app.launchEnvironment["FORUM_SEND_ACTION"] = "reply"
        app.launchEnvironment["FORUM_SEND_INITIAL_SOURCE"] = source
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        let open = app.buttons["forum-feedback-open-editor"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, name: "bbcode-offline-entry")
        open.tap()
        XCTAssertTrue(editor(in: app).waitForExistence(timeout: 10), app.debugDescription)
        capture(app, name: "bbcode-inline-editor")

        let fullScreen = app.buttons["全屏编辑"]
        reveal(fullScreen, in: app)
        fullScreen.tap()
        XCTAssertTrue(app.navigationBars.buttons["完成"].waitForExistence(timeout: 5), app.debugDescription)
        capture(app, name: "bbcode-fullscreen-preview")
        assertVisualContent(in: app)

        let table = app.buttons["表格"].firstMatch
        XCTAssertTrue(table.isHittable, app.debugDescription)
        table.tap()
        let cell = app.buttons["composer-cell-0-0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(cell.value as? String, "Alpha")
        XCTAssertGreaterThan(cell.frame.width, 100)
        XCTAssertTrue(app.buttons["composer-table-confirm"].exists)
        capture(app, name: "bbcode-table-properties")
        let grid = app.scrollViews.containing(.button, identifier: "composer-cell-0-0").firstMatch
        XCTAssertTrue(grid.frame.contains(app.buttons["composer-cell-1-1"].frame), "Small table should not clip its last cell: \(app.debugDescription)")

        app.buttons["行操作"].tap()
        XCTAssertTrue(app.buttons["下方插入行"].waitForExistence(timeout: 5), app.debugDescription)
        capture(app, name: "bbcode-table-row-actions")
        app.buttons["下方插入行"].tap()
        XCTAssertTrue(app.buttons["composer-cell-2-0"].waitForExistence(timeout: 5), app.debugDescription)
        capture(app, name: "bbcode-table-unsaved-row")
        cancelPanel(in: app, confirmationID: "composer-table-confirm")
        assertSource(source, in: app)

        let hide = app.buttons["隐藏内容"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(hide.isHittable, app.debugDescription)
        hide.tap()
        let credits = app.switches["积分条件"]
        XCTAssertTrue(credits.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.switches["期限"].exists)
        capture(app, name: "bbcode-hide-properties")
        let nestedEditor = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Hidden preview remains readable")).firstMatch
        XCTAssertTrue(nestedEditor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(nestedEditor.isHittable, app.debugDescription)
        XCTAssertTrue((nestedEditor.value as? String)?.contains("Hidden preview remains readable") == true)
        toggle(credits)
        expectValue("1", for: credits)
        capture(app, name: "bbcode-hide-unsaved-credits")
        cancelPanel(in: app, confirmationID: "composer-node-confirm")
        assertSource(source, in: app)

        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 5), app.debugDescription)
        capture(app, name: "bbcode-inline-after-fullscreen")
        assertSource(source, in: app)
        let diagnostics = app.staticTexts["forum-send-diagnostics"]
        XCTAssertTrue(diagnostics.label.contains("count=0"), diagnostics.label)
        XCTAssertTrue(diagnostics.label.contains("pending=false"), diagnostics.label)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testExpandedCollapseAndNumberedListRemainReadableFullscreen() throws {
        continueAfterFailure = false
        let source = """
        [b]Layout preview[/b]
        [list=1][*]First numbered item with enough text to wrap onto a second line.[*]Second numbered item[/list]
        [collapse=1,Expanded section][i]Expanded content remains readable[/i][/collapse]
        """
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_SEND_CRASH_FIXTURE"] = "1"
        app.launchEnvironment["FORUM_SEND_ACTION"] = "reply"
        app.launchEnvironment["FORUM_SEND_INITIAL_SOURCE"] = source
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let open = app.buttons["forum-feedback-open-editor"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, name: "bbcode-list-offline-entry")
        open.tap()
        XCTAssertTrue(editor(in: app).waitForExistence(timeout: 10), app.debugDescription)
        capture(app, name: "bbcode-list-inline-preview")
        let fullScreen = app.buttons["全屏编辑"]
        reveal(fullScreen, in: app)
        fullScreen.tap()
        XCTAssertTrue(app.navigationBars.buttons["完成"].waitForExistence(timeout: 5), app.debugDescription)
        capture(app, name: "bbcode-list-collapse-fullscreen")
        let body = editor(in: app)
        XCTAssertTrue((body.value as? String)?.contains("First numbered item") == true)
        XCTAssertTrue((body.value as? String)?.contains("Second numbered item") == true)
        let collapse = app.buttons["折叠"].firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThan(collapse.frame.width, body.frame.width * 0.7)
        XCTAssertTrue(body.frame.contains(collapse.frame), app.debugDescription)
        XCTAssertTrue((collapse.value as? String)?.contains("Expanded content remains readable") == true)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func editor(in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "native-composer-body", "native-form-field-message")).firstMatch
    }

    private func assertVisualContent(in app: XCUIApplication) {
        let body = editor(in: app)
        XCTAssertTrue((body.value as? String)?.contains("Readable BBCode preview") == true, app.debugDescription)
        XCTAssertFalse((body.value as? String)?.contains("[b]") == true)
        for label in ["表格", "隐藏内容"] {
            let block = app.buttons[label].firstMatch
            XCTAssertTrue(block.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertGreaterThan(block.frame.width, body.frame.width * 0.7, "Unreadably narrow \(label) preview")
            XCTAssertTrue(body.frame.contains(block.frame), "Clipped \(label) preview: \(app.debugDescription)")
        }
        XCTAssertTrue((app.buttons["隐藏内容"].firstMatch.value as? String)?.contains("Hidden preview remains readable") == true)
    }

    private func assertSource(_ source: String, in app: XCUIApplication) {
        let sourceToggle = app.switches.matching(NSPredicate(format: "identifier == %@ OR label == %@", "native-composer-plain-text", "源码")).firstMatch
        reveal(sourceToggle, in: app)
        capture(app, name: "bbcode-before-source-mode")
        toggle(sourceToggle)
        expectValue("1", for: sourceToggle)
        capture(app, name: "bbcode-source-toggle-enabled")
        expectValue(source, for: editor(in: app))
        capture(app, name: "bbcode-source-preserved")
        toggle(sourceToggle)
        expectValue("0", for: sourceToggle)
        let visual = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT value CONTAINS %@", "[b]"), object: editor(in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [visual], timeout: 5), .completed, app.debugDescription)
        capture(app, name: "bbcode-visual-restored")
    }

    private func cancelPanel(in app: XCUIApplication, confirmationID: String) {
        app.navigationBars.buttons["取消"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[confirmationID])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, app.debugDescription)
        capture(app, name: "bbcode-panel-cancelled")
    }

    private func toggle(_ wrapper: XCUIElement) {
        let inner = wrapper.descendants(matching: .switch).firstMatch
        (inner.exists ? inner : wrapper).tap()
    }

    private func expectValue(_ value: String, for element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, element.debugDescription)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 4 where !element.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}

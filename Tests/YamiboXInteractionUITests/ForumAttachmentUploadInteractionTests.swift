import XCTest

@MainActor
final class ForumAttachmentUploadInteractionTests: XCTestCase {
    func testLocalFileSelectionAndSameFileReselectionRequireUploadConfirmation() throws {
        continueAfterFailure = false
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(deviceName == "YamiboX-Attachment-Upload-Offline", "Requires an isolated simulator with synthetic fixture documents")
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_ATTACHMENT_UPLOAD_FIXTURE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let upload = app.buttons["上传附件"]
        XCTAssertTrue(upload.waitForExistence(timeout: 10))
        let diagnostics = app.staticTexts["forum-photo-upload-diagnostics"]
        var confirmations: [Bool] = []

        for attempt in 1...2 {
            attachState(app, name: "offline-attachment-editor-before-\(attempt)")
            upload.tap()
            try selectFixtureDocument(app, attempt: attempt)
            let confirm = app.sheets.buttons["上传"].firstMatch
            let appeared = confirm.waitForExistence(timeout: 10)
            confirmations.append(appeared)
            attachState(app, name: "offline-attachment-selection-result-\(attempt)")
            XCTAssertTrue(diagnostics.label.contains("uploads=0"))
            guard appeared else { continue }

            if attempt == 1 {
                let cancel = app.sheets.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
                if cancel.exists { cancel.tap() }
                else { app.otherElements["PopoverDismissRegion"].tap() }
                let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
                XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
                XCTAssertTrue(diagnostics.label.contains("uploads=0"))
            } else {
                confirm.tap()
                let uploaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "uploads=1"), object: diagnostics)
                XCTAssertEqual(XCTWaiter.wait(for: [uploaded], timeout: 8), .completed)
                let toggle = app.switches.firstMatch.descendants(matching: .switch).firstMatch
                XCTAssertTrue(toggle.exists, app.debugDescription)
                toggle.tap()
                let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "[attach]999001[/attach]"), object: app.textViews.firstMatch)
                XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
                attachState(app, name: "offline-attachment-uploaded-body-markup")
            }
        }
        XCTAssertEqual(confirmations, [true, true], "Selecting the local document must present upload confirmation on both attempts")
    }

    private func selectFixtureDocument(_ app: XCUIApplication, attempt: Int) throws {
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription)
        attachState(app, name: "offline-attachment-files-open-\(attempt)")
        let file = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["offline-attachment", "offline-attachment.txt"])).firstMatch
        if !file.exists {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 5), app.debugDescription)
            browse.tap()
            attachState(app, name: "offline-attachment-files-locations-\(attempt)")
            let local = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["On My iPhone", "我的 iPhone"])).firstMatch
            XCTAssertTrue(local.waitForExistence(timeout: 5), app.debugDescription)
            local.tap()
            let host = app.staticTexts["YamiboXTestHost"].firstMatch
            XCTAssertTrue(host.waitForExistence(timeout: 5), app.debugDescription)
            host.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        attachState(app, name: "offline-attachment-file-ready-\(attempt)")
        file.tap()
    }

    private func attachState(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

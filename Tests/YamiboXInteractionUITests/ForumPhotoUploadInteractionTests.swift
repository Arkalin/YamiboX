import XCTest

@MainActor
final class ForumPhotoUploadInteractionTests: XCTestCase {
    func testImagePickerCancellationAndAttachmentFilePickerStayOffline() throws {
        continueAfterFailure = false
        let app = try launchFixture()
        defer { app.terminate() }
        let imageUpload = app.buttons["上传图片"]
        XCTAssertTrue(imageUpload.waitForExistence(timeout: 10))
        imageUpload.tap()
        let cancel = systemCancelButton(in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        attachState(app, name: "offline-photo-picker-cancel")
        cancel.tap()
        XCTAssertTrue(imageUpload.waitForExistence(timeout: 5))
        XCTAssertTrue(diagnostics(in: app).label.contains("uploads=0"))

        let attachmentUpload = app.buttons["上传附件"]
        XCTAssertTrue(attachmentUpload.exists)
        attachmentUpload.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        let filesNavigation = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Browse", "Recents", "浏览", "最近项目"])).firstMatch
        XCTAssertTrue(filesNavigation.waitForExistence(timeout: 5), app.debugDescription)
        attachState(app, name: "offline-attachment-files-picker")
        cancel.tap()
        XCTAssertTrue(diagnostics(in: app).label.contains("uploads=0"))
    }

    func testSelectedPhotoRequiresConfirmationBeforeMockUploadAndBodyInsertion() throws {
        continueAfterFailure = false
        let app = try launchFixture()
        defer { app.terminate() }
        let imageUpload = app.buttons["上传图片"]
        XCTAssertTrue(imageUpload.waitForExistence(timeout: 10))
        imageUpload.tap()
        XCTAssertTrue(systemCancelButton(in: app).waitForExistence(timeout: 10), app.debugDescription)
        // This suite runs only on a dedicated simulator seeded with generated test images.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20), app.debugDescription)
        attachState(app, name: "offline-photo-picker-generated-assets")
        // Photos exposes grid frames but reports these visible remote images as not hittable.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let confirm = app.sheets.buttons["上传"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(diagnostics(in: app).label.contains("uploads=0"))
        attachState(app, name: "offline-photo-upload-confirmation")
        let cancelConfirmation = app.sheets.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        if cancelConfirmation.exists {
            cancelConfirmation.tap()
        } else {
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.exists, app.debugDescription)
            dismissRegion.tap()
        }
        let confirmationDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmationDismissed], timeout: 5), .completed)
        XCTAssertTrue(imageUpload.waitForExistence(timeout: 5))
        XCTAssertTrue(diagnostics(in: app).label.contains("uploads=0"))
        attachState(app, name: "offline-photo-upload-cancelled")
        imageUpload.tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(diagnostics(in: app).label.contains("uploads=0"))
        confirm.tap()
        let uploaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "uploads=1"), object: diagnostics(in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [uploaded], timeout: 8), .completed)
        let summary = diagnostics(in: app).label
        XCTAssertTrue(summary.contains("mime=image/png") || summary.contains("mime=image/jpeg"), summary)
        XCTAssertFalse(summary.contains("bytes=0"), summary)

        let wrapper = app.switches.firstMatch
        let toggle = wrapper.descendants(matching: .switch).firstMatch
        XCTAssertTrue(toggle.exists, app.debugDescription)
        toggle.tap()
        let editor = app.textViews.firstMatch
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "[attachimg]999001[/attachimg]"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(diagnostics(in: app).label.contains("uploads=1"))
        attachState(app, name: "offline-photo-uploaded-body-markup")
    }

    private func launchFixture() throws -> XCUIApplication {
        let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(deviceName == "YamiboX-Photo-Upload-Offline", "Requires the dedicated simulator seeded with generated test photos")
        let app = XCUIApplication()
        app.launchEnvironment["FORUM_PHOTO_UPLOAD_FIXTURE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
        return app
    }

    private func diagnostics(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["forum-photo-upload-diagnostics"]
    }

    private func systemCancelButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
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

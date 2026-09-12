import XCTest

@MainActor
final class MangaVerticalScrollInteractionTests: XCTestCase {
    func testStationaryTapsToggleChromeButScrollsAndShortDragsDoNot() async throws {
        let app = try await launchFixture()
        defer { app.terminate() }
        let viewport = app.collectionViews["manga-vertical-viewport"]
        let diagnostics = app.staticTexts["manga-vertical-diagnostics"]
        let center = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        center.tap()
        try await assertDiagnostics(diagnostics, taps: 1, chrome: 1)
        center.tap()
        try await assertDiagnostics(diagnostics, taps: 2, chrome: 0)

        let initialOffset = try XCTUnwrap(snapshot(diagnostics)["offsetY"])
        viewport.swipeUp()
        XCTAssertGreaterThan(try XCTUnwrap(snapshot(diagnostics)["offsetY"]), initialOffset + 100)
        try await assertDiagnostics(diagnostics, taps: 2, chrome: 0)
        viewport.swipeDown()
        try await assertDiagnostics(diagnostics, taps: 2, chrome: 0)

        // Small scrolling corrections sit close to UIKit's tap/pan recognition threshold.
        for distance in [-18.0, -28.0, 18.0, 28.0] {
            center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: distance)))
            try await assertDiagnostics(diagnostics, taps: 2, chrome: 0)
        }

        try await Task.sleep(for: .milliseconds(500))
        center.tap()
        try await assertDiagnostics(diagnostics, taps: 3, chrome: 1)
        attachScreenshot(app, name: "Stationary chrome toggle after scrolling")
    }

    func testDoubleTapPinchAndZoomedScrollingRemainUsableWithoutChromeToggles() async throws {
        let app = try await launchFixture()
        defer { app.terminate() }
        let viewport = app.collectionViews["manga-vertical-viewport"]
        let diagnostics = app.staticTexts["manga-vertical-diagnostics"]
        let center = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        center.doubleTap()
        XCTAssertEqual(try XCTUnwrap(snapshot(diagnostics)["zoom"]), 2, accuracy: 0.01)
        try await assertDiagnostics(diagnostics, taps: 0, chrome: 0)
        let zoomedOffset = try XCTUnwrap(snapshot(diagnostics)["offsetY"])
        viewport.swipeUp()
        XCTAssertGreaterThan(try XCTUnwrap(snapshot(diagnostics)["offsetY"]), zoomedOffset + 100)
        try await assertDiagnostics(diagnostics, taps: 0, chrome: 0)

        try await Task.sleep(for: .milliseconds(500))
        center.doubleTap()
        XCTAssertEqual(try XCTUnwrap(snapshot(diagnostics)["zoom"]), 1, accuracy: 0.01)
        viewport.pinch(withScale: 1.8, velocity: 1)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot(diagnostics)["zoom"]), 1.2)
        try await assertDiagnostics(diagnostics, taps: 0, chrome: 0)
        let pinchedOffset = try XCTUnwrap(snapshot(diagnostics)["offsetY"])
        viewport.swipeUp()
        XCTAssertGreaterThan(try XCTUnwrap(snapshot(diagnostics)["offsetY"]), pinchedOffset + 100)
        try await assertDiagnostics(diagnostics, taps: 0, chrome: 0)
        attachScreenshot(app, name: "Pinch zoom and scroll without chrome")
    }

    private func launchFixture() async throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MANGA_VERTICAL_SCROLL_FIXTURE"] = "1"
        app.launch()
        let diagnostics = app.staticTexts["manga-vertical-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (try? snapshot(diagnostics)["loaded"]) != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try snapshot(diagnostics)["loaded"], 1)
        try await Task.sleep(for: .milliseconds(500))
        try await assertDiagnostics(diagnostics, taps: 0, chrome: 0)
        return app
    }

    private func snapshot(_ element: XCUIElement) throws -> [String: Double] {
        let value = try XCTUnwrap(element.value as? String)
        return try JSONDecoder().decode([String: Double].self, from: Data(value.utf8))
    }

    private func assertDiagnostics(_ diagnostics: XCUIElement, taps: Double, chrome: Double) async throws {
        // Single taps are deliberately deferred until the double-tap recognizer fails.
        try await Task.sleep(for: .milliseconds(500))
        let values = try snapshot(diagnostics)
        XCTAssertEqual(values["taps"], taps)
        XCTAssertEqual(values["chrome"], chrome)
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

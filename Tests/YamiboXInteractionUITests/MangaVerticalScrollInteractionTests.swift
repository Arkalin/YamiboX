import XCTest

@MainActor
final class MangaVerticalScrollInteractionTests: XCTestCase {
    func testAnimatedResetKeepsVirtualizedPageCoordinatesStable() async throws {
        for (factor, y) in [(2, 3200), (4, 16000)] {
            let app = XCUIApplication()
            app.launchEnvironment["MANGA_VERTICAL_SCROLL_FIXTURE"] = "1"
            app.launchEnvironment["MANGA_VERTICAL_INITIAL_ZOOM"] = String(factor)
            app.launchEnvironment["MANGA_VERTICAL_PAGE_COUNT"] = "60"
            app.launchEnvironment["MANGA_VERTICAL_INITIAL_Y"] = String(y)
            app.launch()
            defer { app.terminate() }
            let diagnostics = app.staticTexts["manga-vertical-diagnostics"]
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertEqual(try XCTUnwrap(snapshot(diagnostics)["zoom"]), Double(factor), accuracy: 0.01)
            app.scrollViews["manga-vertical-viewport"].doubleTap()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while try snapshot(diagnostics)["deferredLayoutApplied"] != 1, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let result = try snapshot(diagnostics)
            XCTAssertEqual(try XCTUnwrap(result["zoom"]), 1, accuracy: 0.01)
            XCTAssertGreaterThan(try XCTUnwrap(result["zoomFrames"]), 2, "\(result)")
            XCTAssertLessThan(try XCTUnwrap(result["windowDrift"]), 1, "\(factor)x reset: \(result)")
            XCTAssertLessThan(try XCTUnwrap(result["pageDrift"]), 1, "\(factor)x reset: \(result)")
            XCTAssertLessThan(try XCTUnwrap(result["contentDrift"]), 1, "\(factor)x reset: \(result)")
            XCTAssertLessThan(try XCTUnwrap(result["imageDrift"]), 1, "\(factor)x reset: \(result)")
            XCTAssertLessThan(try XCTUnwrap(result["centerExcursion"]), 1, "\(factor)x reset: \(result)")
            XCTAssertEqual(result["animatedPageLayers"], 0, "\(factor)x reset: \(result)")
            XCTAssertEqual(result["uncoveredZoomFrames"], 0, "\(result)")
            XCTAssertEqual(result["zoomLayoutChanges"], 0, "\(result)")
            XCTAssertEqual(result["deferredLayoutApplied"], 1, "\(result)")
        }
    }

    func testStationaryTapsToggleChromeButScrollsAndShortDragsDoNot() async throws {
        let app = try await launchFixture()
        defer { app.terminate() }
        let viewport = app.scrollViews["manga-vertical-viewport"]
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
        let viewport = app.scrollViews["manga-vertical-viewport"]
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

    func testChromePreservesNativeZoomAndAllowsPinchAndPan() async throws {
        let app = try await launchFixture()
        defer { app.terminate() }
        let viewport = app.scrollViews["manga-vertical-viewport"]
        let diagnostics = app.staticTexts["manga-vertical-diagnostics"]
        let center = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        viewport.swipeUp()
        try await Task.sleep(for: .milliseconds(500))
        let before = try snapshot(diagnostics)
        center.tap()
        try await assertDiagnostics(diagnostics, taps: 1, chrome: 1)
        let shown = try snapshot(diagnostics)
        XCTAssertEqual(try XCTUnwrap(shown["zoom"]), try XCTUnwrap(before["zoom"]), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(shown["offsetY"]), try XCTUnwrap(before["offsetY"]), accuracy: 2)
        viewport.pinch(withScale: 1.5, velocity: 1)
        let pinched = try snapshot(diagnostics)
        XCTAssertGreaterThan(try XCTUnwrap(pinched["zoom"]), 2.2)
        try await assertDiagnostics(diagnostics, taps: 1, chrome: 1)
        viewport.swipeUp()
        XCTAssertGreaterThan(try XCTUnwrap(snapshot(diagnostics)["offsetY"]), try XCTUnwrap(pinched["offsetY"]) + 100)
        try await assertDiagnostics(diagnostics, taps: 1, chrome: 1)
        let beforeHide = try snapshot(diagnostics)
        center.doubleTap()
        try await assertDiagnostics(diagnostics, taps: 2, chrome: 0)
        let hidden = try snapshot(diagnostics)
        XCTAssertEqual(try XCTUnwrap(hidden["zoom"]), try XCTUnwrap(beforeHide["zoom"]), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(hidden["offsetY"]), try XCTUnwrap(beforeHide["offsetY"]), accuracy: 2)
        attachScreenshot(app, name: "Chrome preserves native zoom and pan")
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

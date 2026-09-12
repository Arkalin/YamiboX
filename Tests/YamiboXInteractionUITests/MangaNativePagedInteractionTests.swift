import XCTest

@MainActor
final class MangaNativePagedInteractionTests: XCTestCase {
    func testNativePinchWithoutChromeUpdate() async throws {
        let app = try await launch(style: "slide", spread: false)
        defer { app.terminate() }
        app.otherElements["manga-native-pinch-area"].pinch(withScale: 2, velocity: 0.8)
        let snapshot = try values(app)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot["zoom"]), 1.4, "\(snapshot)")
    }

    func testNativePinchSurvivesChromeUpdateInEveryBackend() async throws {
        for style in ["slide", "none", "curl"] {
            for spread in [false, true] {
                let app = try await launch(style: style, spread: spread, chromeDuringPinch: true)
                defer { app.terminate() }
                let viewport = app.otherElements["manga-native-pinch-area"]
                XCTAssertTrue(viewport.waitForExistence(timeout: 3))
                let baseline = try values(app)
                viewport.pinch(withScale: 2, velocity: 0.8)
                let pinched = try values(app)
                XCTAssertEqual(pinched["chrome"], 1, "\(style) spread=\(spread)")
                XCTAssertEqual(pinched["page"], baseline["page"], "\(style) spread=\(spread) \(pinched)")
                XCTAssertEqual(pinched["taps"], 0, "\(style) spread=\(spread) \(pinched)")
                XCTAssertGreaterThan(try XCTUnwrap(pinched["zoom"]), 1.4, "\(style) spread=\(spread) before=\(baseline) after=\(pinched)")
                viewport.pinch(withScale: 0.6, velocity: -0.8)
                let reduced = try values(app)
                XCTAssertLessThan(try XCTUnwrap(reduced["zoom"]), try XCTUnwrap(pinched["zoom"]) - 0.2)
                XCTAssertEqual(reduced["chrome"], 1)
                XCTAssertEqual(reduced["page"], baseline["page"])
            }
        }
    }

    func testSingleAndSpreadZoomChromeAndNavigation() async throws {
        for style in ["slide", "none"] {
            for spread in [false, true] {
                let app = try await launch(style: style, spread: spread)
                defer { app.terminate() }
                try await checkZoomAndChrome(app)
                let before = try values(app)["page"]
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: end)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while try values(app)["page"] == before, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let after = try values(app)
                XCTAssertGreaterThan(try XCTUnwrap(after["page"]), try XCTUnwrap(before), "\(style) spread=\(spread) \(after)")
            }
        }
    }

    func testCurlSingleAndSpreadZoomChromeAndNavigation() async throws {
        for spread in [false, true] {
            let app = try await launch(style: "curl", spread: spread)
            defer { app.terminate() }
            try await checkZoomAndChrome(app)
            let before = try values(app)["page"]
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertGreaterThan(try XCTUnwrap(values(app)["page"]), try XCTUnwrap(before))
        }
    }

    private func checkZoomAndChrome(_ app: XCUIApplication) async throws {
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        XCTAssertEqual(try XCTUnwrap(values(app)["zoom"]), 2, accuracy: 0.02)
        let before = try values(app)
        app.buttons["manga-native-chrome"].tap()
        let shown = try values(app)
        XCTAssertEqual(shown["chrome"], 1)
        XCTAssertEqual(shown["taps"], 0)
        XCTAssertEqual(try XCTUnwrap(shown["zoom"]), 2, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(shown["x"]), try XCTUnwrap(before["x"]), accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(shown["y"]), try XCTUnwrap(before["y"]), accuracy: 2)
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: -90, dy: -60)))
        let panned = try values(app)
        XCTAssertEqual(panned["page"], before["page"])
        XCTAssertEqual(panned["chrome"], 1)
        XCTAssertGreaterThan(try XCTUnwrap(panned["x"]), try XCTUnwrap(shown["x"]) + 20)
        center.doubleTap()
        let hidden = try values(app)
        XCTAssertEqual(hidden["chrome"], 0)
        XCTAssertEqual(hidden["taps"], 1)
        XCTAssertEqual(try XCTUnwrap(hidden["zoom"]), 2, accuracy: 0.02)
        center.doubleTap()
        XCTAssertEqual(try XCTUnwrap(values(app)["zoom"]), 1, accuracy: 0.02)
    }

    private func launch(style: String, spread: Bool, chromeDuringPinch: Bool = false) async throws -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["MANGA_PAGED_NATIVE_FIXTURE"] = "1"
        app.launchEnvironment["MANGA_NATIVE_STYLE"] = style
        app.launchEnvironment["MANGA_NATIVE_SPREAD"] = spread ? "1" : "0"
        app.launchEnvironment["MANGA_NATIVE_CHROME_DURING_PINCH"] = chromeDuringPinch ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["manga-native-diagnostics"].waitForExistence(timeout: 5))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try values(app)["loaded"] != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try values(app)["loaded"], 1)
        try await Task.sleep(for: .milliseconds(500))
        return app
    }

    private func values(_ app: XCUIApplication) throws -> [String: Double] {
        let value = try XCTUnwrap(app.staticTexts["manga-native-diagnostics"].value as? String)
        return try JSONDecoder().decode([String: Double].self, from: Data(value.utf8))
    }
}

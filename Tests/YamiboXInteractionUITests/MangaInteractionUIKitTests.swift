import XCTest

@MainActor
final class MangaInteractionUIKitTests: XCTestCase {
    // Exercise native hit testing and coordinate conversion with system-delivered touches.
    func testProductionViewInstallsLongPressInFixedViewport() throws {
        continueAfterFailure = false
        for imageWidth in [400, 600, 800, 1200] {
            try XCTContext.runActivity(named: "Image width \(imageWidth)") { _ in
                let app = XCUIApplication()
                app.launchEnvironment["MANGA_TEST_IMAGE_WIDTH"] = String(imageWidth)
                app.launch()
                defer { app.terminate() }

                let diagnostics = app.staticTexts["manga-diagnostics"]
                XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
                let initial = try snapshot(diagnostics)
                XCTAssertEqual(initial["loaded"], 1)
                XCTAssertEqual(try XCTUnwrap(initial["viewportWidth"]), 400, accuracy: 0.5)
                XCTAssertEqual(try XCTUnwrap(initial["viewportHeight"]), 800, accuracy: 0.5)
                XCTAssertEqual(initial["count"], 0)

                let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let left = center.withOffset(CGVector(dx: -100, dy: 0))
                let right = center.withOffset(CGVector(dx: 100, dy: 0))
                left.press(forDuration: 0.6)
                XCTAssertEqual(try snapshot(diagnostics)["count"], 0)
                center.press(forDuration: 0.6)
                try assertMenu(diagnostics, count: 1)
                right.press(forDuration: 0.6)
                XCTAssertEqual(try snapshot(diagnostics)["count"], 1)

                if imageWidth > 400 {
                    right.press(forDuration: 0.05, thenDragTo: left)
                    XCTAssertLessThan(try XCTUnwrap(snapshot(diagnostics)["offsetX"]), 0)
                    center.press(forDuration: 0.6)
                    try assertMenu(diagnostics, count: 2)
                }
            }
        }
    }

    private func snapshot(_ element: XCUIElement) throws -> [String: Double] {
        try JSONDecoder().decode([String: Double].self, from: Data(element.label.utf8))
    }

    private func assertMenu(_ diagnostics: XCUIElement, count: Double) throws {
        let values = try snapshot(diagnostics)
        XCTAssertEqual(values["count"], count)
        XCTAssertEqual(try XCTUnwrap(values["menuMidX"]), 200, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(values["menuWidth"]), 400.0 / 3, accuracy: 0.5)
    }
}

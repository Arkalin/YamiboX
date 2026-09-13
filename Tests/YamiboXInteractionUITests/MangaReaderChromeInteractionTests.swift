import UIKit
import XCTest

@MainActor
final class MangaReaderChromeInteractionTests: XCTestCase {
    func testNoneChromePreservesFullReaderPageGeometry() async throws {
        try await checkStyle("none")
    }

    func testSlideChromePreservesFullReaderPageGeometry() async throws {
        try await checkStyle("slide")
    }

    func testQuickFadeChromePreservesFullReaderPageGeometry() async throws {
        try await checkStyle("quickFade")
    }

    func testPageCurlChromePreservesFullReaderPageGeometry() async throws {
        try await checkStyle("pageCurl")
    }

    private func checkStyle(_ style: String) async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad simulator for real landscape spreads")
        continueAfterFailure = false
        let originalOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = originalOrientation }
        for spread in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["MANGA_READER_CHROME_FIXTURE"] = "1"
            app.launchEnvironment["MANGA_READER_STYLE"] = style
            app.launchEnvironment["MANGA_READER_SPREAD"] = spread ? "1" : "0"
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            defer { app.terminate() }
            let label = "\(style)-\(spread ? "spread" : "single")"
            let diagnostics = app.descendants(matching: .any).matching(identifier: "manga-reader-fixture-geometry").firstMatch
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 10), label)
            let pageCount = spread ? 2 : 1
            let baseline = try await waitForChrome(true, pageCount: pageCount, diagnostics: diagnostics)
            XCTAssertGreaterThan(baseline.window[2], baseline.window[3], "Expected landscape: \(baseline.window)")
            if style == "pageCurl" {
                XCTAssertTrue(baseline.collections.isEmpty)
            } else {
                XCTAssertEqual(baseline.collections.count, 1)
            }
            attach(app, diagnostics: diagnostics, name: "\(label)-initial-shown")

            for (index, chrome) in [false, true, false, true].enumerated() {
                let state = "\(label)-\(index)-\(chrome ? "shown" : "hidden")"
                let changed = try await setChrome(chrome, app: app, pageCount: pageCount, diagnostics: diagnostics)
                attach(app, diagnostics: diagnostics, name: state)
                assertGeometry(changed, equals: baseline, state: state)
            }
        }
    }

    private func setChrome(
        _ visible: Bool,
        app: XCUIApplication,
        pageCount: Int,
        diagnostics: XCUIElement
    ) async throws -> Snapshot {
        // Send real center taps; single taps wait for double-tap admission.
        for _ in 0..<2 {
            if let current = try? snapshot(diagnostics), current.matchesChrome(visible, pageCount: pageCount) {
                return try await waitForChrome(visible, pageCount: pageCount, diagnostics: diagnostics)
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                if let current = try? snapshot(diagnostics), current.matchesChrome(visible, pageCount: pageCount) {
                    return try await waitForChrome(visible, pageCount: pageCount, diagnostics: diagnostics)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        attach(app, diagnostics: diagnostics, name: "chrome-toggle-failed")
        return try await waitForChrome(visible, pageCount: pageCount, diagnostics: diagnostics)
    }

    private func waitForChrome(_ visible: Bool, pageCount: Int, diagnostics: XCUIElement) async throws -> Snapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var previous: Snapshot?
        var stableSamples = 0
        while ContinuousClock.now < deadline {
            if let current = try? snapshot(diagnostics), current.matchesChrome(visible, pageCount: pageCount) {
                stableSamples = current == previous ? stableSamples + 1 : 0
                previous = current
                if stableSamples >= 3 { return current }
            } else {
                stableSamples = 0
                previous = nil
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        let current = try snapshot(diagnostics)
        XCTAssertTrue(current.matchesChrome(visible, pageCount: pageCount), "Expected chrome=\(visible), \(current)")
        XCTFail("Full reader geometry did not settle after chrome transition")
        return current
    }

    private func assertGeometry(_ current: Snapshot, equals baseline: Snapshot, state: String) {
        assertNumbers(current.window, baseline.window, state: "\(state) window")
        XCTAssertEqual(current.imageSurfaces.count, baseline.imageSurfaces.count, state)
        for (index, pair) in zip(current.imageSurfaces, baseline.imageSurfaces).enumerated() {
            assertNumbers(pair.0.imageFrame ?? [], pair.1.imageFrame ?? [], state: "\(state) image \(index)")
            assertNumbers(pair.0.frame, pair.1.frame, state: "\(state) surface \(index)")
            assertNumbers(pair.0.offset, pair.1.offset, state: "\(state) image offset \(index)")
        }
        XCTAssertEqual(current.collections.count, baseline.collections.count, state)
        for (index, pair) in zip(current.collections, baseline.collections).enumerated() {
            assertNumbers(pair.0.frame, pair.1.frame, state: "\(state) collection \(index)")
            assertNumbers(pair.0.contentOffset, pair.1.contentOffset, state: "\(state) collection offset \(index)")
        }
    }

    private func assertNumbers(_ current: [Double], _ baseline: [Double], state: String) {
        XCTAssertEqual(current.count, baseline.count, state)
        for (index, pair) in zip(current, baseline).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: 1, "\(state) component \(index); before=\(baseline), after=\(current)")
        }
    }

    private func snapshot(_ element: XCUIElement) throws -> Snapshot {
        guard let json = element.value as? String else { throw SnapshotFailure.unavailable }
        return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    private enum SnapshotFailure: Error {
        case unavailable
    }

    private func attach(_ app: XCUIApplication, diagnostics: XCUIElement, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if let json = diagnostics.value as? String {
            let attachment = XCTAttachment(string: json)
            attachment.name = "\(name)-geometry"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private struct Snapshot: Decodable, Equatable {
        let window: [Double]
        let statusBarHidden: Bool
        let surfaces: [Surface]
        let collections: [Collection]

        var imageSurfaces: [Surface] {
            surfaces.filter { $0.imageFrame != nil }.sorted { $0.frame[0] < $1.frame[0] }
        }

        func matchesChrome(_ visible: Bool, pageCount: Int) -> Bool {
            statusBarHidden == !visible && imageSurfaces.count == pageCount
                && imageSurfaces.allSatisfy { $0.chrome == visible }
                && imageSurfaces.allSatisfy { ($0.imageFrame?[2] ?? 0) > 0 && ($0.imageFrame?[3] ?? 0) > 0 }
        }
    }

    private struct Surface: Decodable, Equatable {
        let frame: [Double]
        let imageFrame: [Double]?
        let offset: [Double]
        let chrome: Bool
        let zoom: Double
    }

    private struct Collection: Decodable, Equatable {
        let frame: [Double]
        let contentOffset: [Double]
    }
}

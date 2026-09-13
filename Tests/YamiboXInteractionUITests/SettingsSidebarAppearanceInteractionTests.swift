import XCTest
import UIKit

@MainActor
final class SettingsSidebarAppearanceInteractionTests: XCTestCase {
    func testPushedSettingsUsesGroupedRowsOnlyInCompactLayout() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires the fixed-width iPad appearance fixture")
        let originalOrientation = XCUIDevice.shared.orientation
        // This fixture tests list appearance, not rotation. Keep screenshot and
        // accessibility coordinates in the same portrait coordinate space.
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = originalOrientation }

        for isDark in [false, true] {
            for isCompact in [false, true] {
                let app = XCUIApplication()
                app.launchEnvironment = [
                    "SETTINGS_SIDEBAR_APPEARANCE_FIXTURE": "1",
                    "SETTINGS_SIDEBAR_APPEARANCE_DARK": isDark ? "1" : "0",
                    "SETTINGS_SIDEBAR_APPEARANCE_COMPACT": isCompact ? "1" : "0"
                ]
                app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
                app.launch()
                defer { app.terminate() }
                let open = app.buttons["settings.appearance.open"]
                XCTAssertTrue(open.waitForExistence(timeout: 10))
                open.tap()
                let logout = app.buttons["settings.sidebar.signOut"]
                XCTAssertTrue(logout.waitForExistence(timeout: 5))
                XCTAssertTrue(logout.isHittable)
                let sidebar = app.descendants(matching: .any).matching(identifier: "settings.sidebar").firstMatch
                XCTAssertTrue(sidebar.exists)
                XCTAssertEqual(sidebar.frame.width, 375, accuracy: 2)
                XCTAssertTrue(sidebar.buttons["通用"].firstMatch.isSelected)

                let screenshot = app.screenshot()
                let name = "settings-\(isCompact ? "compact" : "regular")-\(isDark ? "dark" : "light")"
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = name + "-hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)

                let sampleX = sidebar.frame.maxX - 48
                let logoutColor = try pixel(screenshot.image, screenPoint: CGPoint(x: sampleX, y: logout.frame.midY), appFrame: app.frame)
                var samples = ["app=\(app.frame) sidebar=\(sidebar.frame) screenshot=\(screenshot.image.size) orientation=\(screenshot.image.imageOrientation.rawValue)",
                    "logout=\(logout.frame), sampleX=\(sampleX), rgb=\(logoutColor)"]
                defer {
                    let diagnostic = XCTAttachment(string: samples.joined(separator: "\n"))
                    diagnostic.name = name + "-pixel-samples"
                    diagnostic.lifetime = .keepAlways
                    add(diagnostic)
                }

                if isCompact {
                    let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
                    let expectedRow = components(of: .secondarySystemGroupedBackground, traits: traits)
                    samples.append("expected grouped row=\(expectedRow)")
                    assertColor(logoutColor, equals: expectedRow, message: "\(name): logout grouped row")
                    // All rows, including the selected row, retain the same grouped fill.
                    for title in ["通用", "主页", "论坛", "收藏", "阅读", "数据与存储", "About"] {
                        let row = sidebar.buttons[title].firstMatch
                        XCTAssertTrue(row.exists, title)
                        guard row.exists else { continue }
                        XCTAssertTrue(row.isHittable, title)
                        let rowColor = try pixel(screenshot.image, screenPoint: CGPoint(x: sampleX, y: row.frame.midY), appFrame: app.frame)
                        samples.append("\(title)=\(row.frame), rgb=\(rowColor)")
                        assertColor(rowColor, equals: logoutColor, message: "\(name): \(title) matches logout grouped fill")
                    }
                } else {
                    // The regular canvas belongs to the native navigation container,
                    // not to a fixed secondarySystemBackground color.
                    let canvasColor = try pixel(screenshot.image,
                        screenPoint: CGPoint(x: sidebar.frame.minX + 4, y: logout.frame.midY), appFrame: app.frame)
                    samples.append("native canvas rgb=\(canvasColor)")
                    assertColor(logoutColor, equals: canvasColor, message: "\(name): logout blends into sidebar canvas")
                }
            }
        }
    }

    private func components(of color: UIColor, traits: UITraitCollection) -> [Double] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue].map { Double($0 * 255) }
    }

    private func pixel(_ image: UIImage, screenPoint: CGPoint, appFrame: CGRect) throws -> [Double] {
        // Drawing a UIImage applies its orientation before using AX coordinates.
        let normalized = UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        let source = try XCTUnwrap(normalized.cgImage)
        XCTAssertEqual(image.size.width / image.size.height, appFrame.width / appFrame.height,
            accuracy: 0.001, "Screenshot and accessibility coordinate spaces must agree")
        XCTAssertTrue(appFrame.contains(screenPoint), "Sample must lie inside the application")
        let x = (screenPoint.x - appFrame.minX) * CGFloat(source.width) / appFrame.width
        let y = (screenPoint.y - appFrame.minY) * CGFloat(source.height) / appFrame.height
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: floor(x), y: floor(y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Double.init)
    }

    private func assertColor(_ actual: [Double], equals expected: [Double], message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            XCTAssertEqual(actual[channel], expected[channel], accuracy: 4,
                "\(message), channel \(channel)", file: file, line: line)
        }
    }
}

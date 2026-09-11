import UIKit
import XCTest

@MainActor
final class ChapterCommentImageInteractionTests: XCTestCase {
    func testImagesLoadOnlyAfterTapStartAtSecondAndReturnInPlace() {
        let app = launch()
        defer { app.terminate() }
        XCTAssertEqual(app.staticTexts["chapter-image-loads"].label, "loads=0")
        let first = app.buttons["chapter-comment-image-photos-one"]
        let second = app.buttons["chapter-comment-image-photos-two"]
        XCTAssertTrue(first.isHittable)
        XCTAssertTrue(second.isHittable)
        XCTAssertEqual(first.label, "查看图片")
        XCTAssertLessThan(first.frame.midY, app.staticTexts["两张之间。"].frame.midY)
        XCTAssertLessThan(app.staticTexts["两张之间。"].frame.midY, second.frame.midY)
        XCTAssertLessThan(app.buttons["chapter-comment-original-photos"].frame.midY, first.frame.minY)
        XCTAssertGreaterThan(app.staticTexts["2026-09-10 12:30"].frame.midY, second.frame.maxY)
        let position = second.frame
        attach(app, "comment-image-links-light")

        second.tap()
        XCTAssertTrue(app.staticTexts["第 2 张，共 2 张"].waitForExistence(timeout: 8))
        waitForPixels(app, green: true)
        attach(app, "comment-image-second-loaded")
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["第 1 张，共 2 张"].waitForExistence(timeout: 5))
        waitForPixels(app, green: false)
        attach(app, "comment-image-first-loaded")
        closeBrowser(app)
        XCTAssertEqual(second.frame.midY, position.midY, accuracy: 2)
        XCTAssertEqual(second.frame.minX, position.minX, accuracy: 2)

        app.buttons["chapter-comment-original-photos"].tap()
        XCTAssertTrue(app.staticTexts["Offline destination"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let reply = app.buttons["chapter-comment-reply-789"]
        if !reply.isHittable { app.swipeUp() }
        XCTAssertTrue(reply.isHittable)
        reply.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 8))
    }

    func testImageOnlyFailureRetryAndReturn() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["chapter-comment-image-failed-missing"].tap()
        XCTAssertTrue(app.staticTexts["图片加载失败"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["第 1 张，共 2 张"].exists)
        let retry = app.buttons["重试"]
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(app.staticTexts["图片加载失败"].waitForExistence(timeout: 8))
        attach(app, "comment-image-failure")
        closeBrowser(app)
        XCTAssertTrue(app.buttons["chapter-comment-image-failed-missing"].isHittable)
        XCTAssertEqual(app.staticTexts["chapter-image-loads"].label, "loads=2")
    }

    func testDarkLargeTextLinksRemainTappableAndScrollPositionIsPreserved() {
        let app = launch(extra: ["CHAPTER_COMMENT_DARK": "1", "CHAPTER_COMMENT_LARGE_TEXT": "1"])
        defer { app.terminate() }
        let second = app.buttons["chapter-comment-image-photos-two"]
        if !second.isHittable { app.swipeUp() }
        XCTAssertTrue(second.isHittable)
        XCTAssertGreaterThanOrEqual(second.frame.height, 44)
        XCTAssertLessThanOrEqual(second.frame.maxX, app.frame.maxX - 8)
        let position = second.frame
        attach(app, "comment-image-links-dark-large")
        second.tap()
        waitForPixels(app, green: true)
        closeBrowser(app)
        XCTAssertEqual(second.frame.midY, position.midY, accuracy: 2)
        XCTAssertTrue(app.buttons["chapter-comment-compose"].isHittable)
    }

    private func launch(extra: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["CHAPTER_COMMENT_FIXTURE": "1", "CHAPTER_COMMENT_IMAGES": "1"].merging(extra) { _, new in new }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["chapter-comment-compose"].waitForExistence(timeout: 10))
        return app
    }

    private func closeBrowser(_ app: XCUIApplication) {
        app.buttons["关闭"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["关闭"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func waitForPixels(_ app: XCUIApplication, green: Bool) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.coloredPixels(app.screenshot().image, green: green) > 250
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed, "The browser must display decoded fixture pixels, not just an image placeholder")
    }

    private func coloredPixels(_ image: UIImage, green: Bool) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return stride(from: 0, to: buffer.count, by: 4).filter { index in
                let red = Int(buffer[index]), g = Int(buffer[index + 1]), blue = Int(buffer[index + 2])
                return green ? (g > 100 && g > red * 3 / 2 && g > blue * 3 / 2) : (red > 150 && red > g * 3 / 2 && red > blue * 3 / 2)
            }.count
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import CoreGraphics
import XCTest
@testable import YamiboXUI

final class ImageBrowserSwipeDismissGestureTests: XCTestCase {
    func testSwipeDownDismissRequiresMinimumZoomAndDownwardIntent() {
        XCTAssertTrue(ImageBrowserSwipeDismissGesture.canBegin(
            translation: CGPoint(x: 12, y: 80),
            zoomScale: 1,
            minimumZoomScale: 1
        ))
        XCTAssertTrue(ImageBrowserSwipeDismissGesture.shouldDismiss(
            translation: CGPoint(x: 12, y: 120),
            velocity: CGPoint(x: 0, y: 700),
            zoomScale: 1,
            minimumZoomScale: 1
        ))
        XCTAssertFalse(ImageBrowserSwipeDismissGesture.shouldDismiss(
            translation: CGPoint(x: 12, y: 120),
            velocity: CGPoint(x: 0, y: 900),
            zoomScale: 1.2,
            minimumZoomScale: 1
        ))
        XCTAssertFalse(ImageBrowserSwipeDismissGesture.canBegin(
            translation: CGPoint(x: 120, y: 80),
            zoomScale: 1,
            minimumZoomScale: 1
        ))
        XCTAssertFalse(ImageBrowserSwipeDismissGesture.shouldDismiss(
            translation: CGPoint(x: 12, y: 70),
            velocity: CGPoint(x: 0, y: 300),
            zoomScale: 1,
            minimumZoomScale: 1
        ))
    }

    func testSwipeDownDismissVisualProgressIsClamped() {
        XCTAssertEqual(ImageBrowserSwipeDismissGesture.progress(for: -40), 0)
        XCTAssertEqual(ImageBrowserSwipeDismissGesture.progress(for: 75), 0.5)
        XCTAssertEqual(ImageBrowserSwipeDismissGesture.progress(for: 300), 1)
        XCTAssertEqual(ImageBrowserSwipeDismissGesture.imageScale(for: 1), 0.92, accuracy: 0.001)
    }
}

import CoreGraphics
import XCTest
import UIKit
import YamiboXCore
@testable import YamiboXUI

final class NovelNovelReaderVerticalPositioningTests: XCTestCase {
    @MainActor
    func testImageGeometryRestoreUsesSamplingReferenceLineImmediatelyAfterAttach() {
        for height in [568.0, 852.0, 1024.0] {
            let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: height))
            scrollView.contentSize = CGSize(width: 390, height: 3000)
            scrollView.contentOffset.y = 300
            let coordinator = NovelReaderVerticalScrollCoordinator()
            coordinator.attach(scrollView: scrollView)
            let referenceLine = NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: scrollView.bounds)
            XCTAssertEqual(coordinator.referenceLineY, referenceLine, accuracy: 0.001)
            let imageFrame = CGRect(x: 0, y: 200, width: 390, height: 500)
            XCTAssertTrue(coordinator.restoreOffset(to: imageFrame, intraSurfaceProgress: 0))
            let restoredFrame = imageFrame.offsetBy(dx: 0, dy: 300 - scrollView.contentOffset.y)
            // UIScrollView rounds its content offset to display pixels.
            XCTAssertEqual(restoredFrame.minY, referenceLine, accuracy: 0.5)
            XCTAssertEqual(NovelReaderVerticalPositioning.nearestSurfaceIndex(to: referenceLine, frames: [
                0: CGRect(x: 0, y: restoredFrame.minY - 214, width: 390, height: 200),
                1: restoredFrame,
            ]), 1)
            coordinator.attach(scrollView: nil)
        }
    }

    func testNearestSurfaceIncludesImageBetweenVisibleTextSurfaces() {
        let frames = [
            0: CGRect(x: 0, y: -40, width: 320, height: 120),
            1: CGRect(x: 0, y: 94, width: 320, height: 400),
            2: CGRect(x: 0, y: 508, width: 320, height: 200),
        ]
        XCTAssertEqual(NovelReaderVerticalPositioning.nearestSurfaceIndex(to: 160, frames: frames), 1)
        XCTAssertEqual(NovelReaderVerticalPositioning.nearestSurfaceIndex(to: 40, frames: frames), 0)
        XCTAssertEqual(NovelReaderVerticalPositioning.nearestSurfaceIndex(to: 550, frames: frames), 2)
    }

    func testNearestSurfaceHandlesImageOnlyViewportAndStableTies() {
        let first = CGRect(x: 0, y: -100, width: 320, height: 200)
        let second = CGRect(x: 0, y: 120, width: 320, height: 400)
        XCTAssertEqual(NovelReaderVerticalPositioning.nearestSurfaceIndex(to: 160, frames: [7: second]), 7)
        XCTAssertEqual(NovelReaderVerticalPositioning.nearestSurfaceIndex(to: 110, frames: [7: second, 6: first]), 6)
        XCTAssertNil(NovelReaderVerticalPositioning.nearestSurfaceIndex(to: 160, frames: [:]))
    }

    func testViewportReadingAnchorLineMatchesProgressSamplingAnchor() {
        let bounds = CGRect(x: 0, y: 12, width: 393, height: 852)

        XCTAssertEqual(NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: bounds), 136.32, accuracy: 0.001)
    }

    func testViewportReadingAnchorLineUsesTopReadingArea() {
        let bounds = CGRect(x: 0, y: 12, width: 393, height: 852)

        XCTAssertEqual(NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: bounds), 136.32, accuracy: 0.001)
    }

    func testVerticalSamplingAndRestoreUseSharedReadingAnchorLine() {
        let boundsSamples = [
            CGRect(x: 0, y: 0, width: 320, height: 568),
            CGRect(x: 0, y: 12, width: 393, height: 852),
            CGRect(x: 0, y: 24, width: 768, height: 1024),
        ]

        for bounds in boundsSamples {
            XCTAssertEqual(NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: bounds), expectedAnchorLineY(for: bounds), accuracy: 0.001)
        }
    }

    func testViewportReadingAnchorLineIgnoresScrollOffsetOrigin() {
        let scrolledBounds = CGRect(x: 0, y: 7_403, width: 393, height: 852)

        XCTAssertEqual(NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: scrolledBounds), 136.32, accuracy: 0.001)
        XCTAssertNotEqual(NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: scrolledBounds), scrolledBounds.midY)
    }

    func testPageDistanceReportsZeroOnlyWhenReferenceLineCrossesFrame() {
        let containingFrame = CGRect(x: 0, y: 120, width: 320, height: 500)
        let aboveFrame = CGRect(x: 0, y: 240, width: 320, height: 500)
        let belowFrame = CGRect(x: 0, y: -300, width: 320, height: 400)

        XCTAssertEqual(NovelReaderVerticalPositioning.pageDistance(from: 160, to: containingFrame), 0)
        XCTAssertEqual(NovelReaderVerticalPositioning.pageDistance(from: 160, to: aboveFrame), 80)
        XCTAssertEqual(NovelReaderVerticalPositioning.pageDistance(from: 160, to: belowFrame), 60)
    }

}

private func expectedAnchorLineY(for bounds: CGRect) -> CGFloat {
    min(max(bounds.height * 0.16, 96), max(bounds.height - 96, 0))
}

import CoreGraphics
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class NovelNovelReaderVerticalPositioningTests: XCTestCase {
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

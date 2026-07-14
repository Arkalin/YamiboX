import XCTest
@testable import YamiboXUI

final class NovelNovelReaderVerticalViewportPositionUpdateTimingTests: XCTestCase {
    func testTextViewportSampleChangeAppliesProgressImmediately() {
        XCTAssertEqual(
            NovelReaderVerticalViewportPositionUpdateTiming.updateMode(for: .textViewportSampleChanged),
            .immediate
        )
    }

    func testViewportGeometryChangeMayStayDeferred() {
        XCTAssertEqual(
            NovelReaderVerticalViewportPositionUpdateTiming.updateMode(for: .viewportGeometryChanged),
            .deferred
        )
    }
}

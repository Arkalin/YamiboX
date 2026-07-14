import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class NovelReaderVerticalRestoreControllerTests: XCTestCase {
    func testScrollRequestIdentitySeparatesRepeatedSemanticRestores() {
        let anchor = NovelReaderVerticalTextAnchor(
            position: NovelResumePoint(
                view: 1,
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-3"),
                displayedTextOffset: 42,
                chapterOrdinal: 0,
                segmentProgress: 0,
                readingModeHint: .vertical
            )
        )
        let first = NovelReaderVerticalScrollRequest(
            commandID: 1,
            view: 1,
            surfaceIndex: 12,
            intraSurfaceProgress: 0.59,
            textAnchor: anchor
        )
        let second = NovelReaderVerticalScrollRequest(
            commandID: 2,
            view: 1,
            surfaceIndex: 12,
            intraSurfaceProgress: 0.59,
            textAnchor: anchor
        )

        XCTAssertNotEqual(first, second)
    }

    func testActiveRestoreSuppressesViewportSamplingIncludingForcedSave() {
        var controller = ReaderVerticalRestoreController()
        let request = NovelReaderVerticalScrollRequest(surfaceIndex: 81, intraSurfaceProgress: 0.0194)

        controller.beginScrolling(to: request)

        XCTAssertEqual(controller.activeRequest, request)
        XCTAssertFalse(controller.canSampleViewport(now: 10))
    }

    func testScrollingRestoreStaysActiveForLateFrameRetryUntilFineTuneSettles() {
        var controller = ReaderVerticalRestoreController()
        let request = NovelReaderVerticalScrollRequest(surfaceIndex: 81, intraSurfaceProgress: 0.0194)

        controller.beginScrolling(to: request)
        XCTAssertTrue(controller.shouldConcealViewportContent)
        controller.refresh(now: 100)
        XCTAssertEqual(controller.scrollingRequest, request)

        controller.beginFineTuning(request)
        XCTAssertTrue(controller.shouldConcealViewportContent)
        XCTAssertFalse(controller.canSampleViewport(now: 101))

        controller.beginSettling(request, now: 101, duration: 0.45)
        XCTAssertFalse(controller.shouldConcealViewportContent)
        XCTAssertFalse(controller.canSampleViewport(now: 101.44))
        XCTAssertTrue(controller.canSampleViewport(now: 101.45))
        XCTAssertNil(controller.activeRequest)
    }

    func testTextAnchorScrollingRestoreConcealsViewportWhileWaitingForLateLayout() {
        var controller = ReaderVerticalRestoreController()
        let request = NovelReaderVerticalScrollRequest(
            surfaceIndex: 12,
            intraSurfaceProgress: 0.59,
            textAnchor: NovelReaderVerticalTextAnchor(
                position: NovelResumePoint(
                    view: 1,
                    textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "text-3"),
                    displayedTextOffset: 42,
                    chapterOrdinal: 0,
                    segmentProgress: 0,
                    readingModeHint: .vertical
                )
            )
        )

        controller.beginScrolling(to: request)

        XCTAssertTrue(controller.shouldConcealViewportContent)
        XCTAssertFalse(controller.canSampleViewport(now: 10))
        XCTAssertEqual(controller.scrollingRequest, request)

        controller.beginSettling(request, now: 10, duration: 0.45)
        XCTAssertFalse(controller.shouldConcealViewportContent)
    }

    func testUserScrollCancelSuppressesViewportSamplingUntilCooldownEnds() {
        var controller = ReaderVerticalRestoreController()
        let request = NovelReaderVerticalScrollRequest(surfaceIndex: 80, intraSurfaceProgress: 0.97)

        controller.beginScrolling(to: request)
        controller.cancel(now: 20, samplingCooldown: 0.25)

        XCTAssertNil(controller.activeRequest)
        XCTAssertFalse(controller.canSampleViewport(now: 20.24))
        XCTAssertTrue(controller.canSampleViewport(now: 20.25))
    }

    func testFineTuneSettlingSuppressesForcedSaveSamplingUntilDeadline() {
        var controller = ReaderVerticalRestoreController()
        let request = NovelReaderVerticalScrollRequest(surfaceIndex: 12, intraSurfaceProgress: 0.59)

        controller.beginFineTuning(request)
        controller.beginSettling(request, now: 30, duration: 0.45)

        XCTAssertFalse(controller.canSampleViewport(now: 30.44))
        XCTAssertTrue(controller.canSampleViewport(now: 30.45))
    }
}

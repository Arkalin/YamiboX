import CoreGraphics
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

final class NovelTextDisplayAdapterTests: XCTestCase {
    func testPagedTapZoneKeepsBlankAreaNavigationAvailable() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)

        XCTAssertEqual(ReaderPagedTapZone.zone(for: CGPoint(x: 40, y: 720), in: bounds), .previous)
        XCTAssertEqual(ReaderPagedTapZone.zone(for: CGPoint(x: 190, y: 720), in: bounds), .toggleChrome)
        XCTAssertEqual(ReaderPagedTapZone.zone(for: CGPoint(x: 340, y: 720), in: bounds), .next)
    }

    func testPagedBoundaryPageTurnDetectsOnlyArmedHorizontalBoundaryGestures() {
        XCTAssertEqual(
            ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: 0,
                itemCount: 3,
                translation: CGPoint(x: 80, y: 4),
                velocity: .zero,
                viewportWidth: 390,
                canBoundaryPageTurn: { $0 == -1 }
            ),
            -1
        )
        XCTAssertEqual(
            ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: 2,
                itemCount: 3,
                translation: CGPoint(x: -80, y: 4),
                velocity: .zero,
                viewportWidth: 390,
                canBoundaryPageTurn: { $0 == 1 }
            ),
            1
        )
        XCTAssertEqual(
            ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: 0,
                itemCount: 1,
                translation: CGPoint(x: -80, y: 4),
                velocity: .zero,
                viewportWidth: 390,
                canBoundaryPageTurn: { $0 == 1 }
            ),
            1
        )
        XCTAssertEqual(
            ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: 0,
                itemCount: 1,
                translation: CGPoint(x: 80, y: 4),
                velocity: .zero,
                viewportWidth: 390,
                canBoundaryPageTurn: { $0 == -1 }
            ),
            -1
        )
        XCTAssertEqual(
            ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: 0,
                itemCount: 3,
                translation: .zero,
                velocity: CGPoint(x: -500, y: 20),
                viewportWidth: 390,
                canBoundaryPageTurn: { $0 == 1 }
            ),
            nil
        )
        XCTAssertEqual(
            ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: 2,
                itemCount: 3,
                translation: .zero,
                velocity: CGPoint(x: -500, y: 20),
                viewportWidth: 390,
                canBoundaryPageTurn: { $0 == 1 }
            ),
            1
        )
        XCTAssertNil(ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: 1,
            itemCount: 3,
            translation: CGPoint(x: -80, y: 4),
            velocity: .zero,
            viewportWidth: 390,
            canBoundaryPageTurn: { _ in true }
        ))
        XCTAssertNil(ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: 2,
            itemCount: 3,
            translation: CGPoint(x: -20, y: 4),
            velocity: .zero,
            viewportWidth: 390,
            canBoundaryPageTurn: { _ in true }
        ))
        XCTAssertNil(ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: 2,
            itemCount: 3,
            translation: CGPoint(x: -100, y: 150),
            velocity: .zero,
            viewportWidth: 390,
            canBoundaryPageTurn: { _ in true }
        ))
        XCTAssertNil(ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: 2,
            itemCount: 3,
            translation: CGPoint(x: -80, y: 4),
            velocity: .zero,
            viewportWidth: 390,
            canBoundaryPageTurn: { _ in false }
        ))
    }

    func testPagedBoundaryPageTurnMapsHorizontalDirection() {
        let leftSwipeDelta = ReaderPagedBoundaryPageTurn.horizontalDelta(
            translation: CGPoint(x: -80, y: 4),
            velocity: .zero,
            viewportWidth: 390
        )
        XCTAssertEqual(leftSwipeDelta, 1)
        XCTAssertEqual(
            leftSwipeDelta.map {
                ReaderPagedBoundaryPageTurn.directionalDelta($0, direction: .leftSwipeAdvances)
            },
            1
        )
        XCTAssertEqual(
            leftSwipeDelta.map {
                ReaderPagedBoundaryPageTurn.directionalDelta($0, direction: .rightSwipeAdvances)
            },
            -1
        )
        XCTAssertEqual(
            ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: 0,
                itemCount: 1,
                translation: CGPoint(x: -80, y: 4),
                velocity: .zero,
                viewportWidth: 390,
                horizontalNavigationDirection: .rightSwipeAdvances,
                canBoundaryPageTurn: { $0 == -1 }
            ),
            -1
        )
    }

    func testNovelPageTurnDirectionMapsGesturesAndTapZones() {
        XCTAssertEqual(ReaderPageTurnDirection.leftToRight.horizontalNavigationDirection, .leftSwipeAdvances)
        XCTAssertEqual(ReaderPageTurnDirection.rightToLeft.horizontalNavigationDirection, .rightSwipeAdvances)

        XCTAssertEqual(ReaderPageTurnDirection.leftToRight.directionalTapZone(for: .previous), .previous)
        XCTAssertEqual(ReaderPageTurnDirection.leftToRight.directionalTapZone(for: .next), .next)
        XCTAssertEqual(ReaderPageTurnDirection.rightToLeft.directionalTapZone(for: .previous), .next)
        XCTAssertEqual(ReaderPageTurnDirection.rightToLeft.directionalTapZone(for: .next), .previous)
        XCTAssertEqual(ReaderPageTurnDirection.rightToLeft.directionalTapZone(for: .toggleChrome), .toggleChrome)

        XCTAssertEqual(ReaderPageTurnDirection.leftToRight.progressFillDirection, .leftToRight)
        XCTAssertEqual(ReaderPageTurnDirection.rightToLeft.progressFillDirection, .rightToLeft)
    }

    func testNovelPageTurnDirectionMapsPagedItemOrder() {
        XCTAssertEqual(ReaderPageTurnDirection.leftToRight.itemIndex(forSelectionIndex: 0, itemCount: 4), 0)
        XCTAssertEqual(ReaderPageTurnDirection.leftToRight.selectionIndex(forItemIndex: 3, itemCount: 4), 3)
        XCTAssertEqual(ReaderPageTurnDirection.rightToLeft.itemIndex(forSelectionIndex: 0, itemCount: 4), 3)
        XCTAssertEqual(ReaderPageTurnDirection.rightToLeft.selectionIndex(forItemIndex: 0, itemCount: 4), 3)
    }

    func testPageCurlSequenceMapsSinglePagesBySurfaceIndex() {
        let surfaces = makePageCurlSurfaces(count: 3)
        let sequence = NovelReaderPagedPageCurlSequence(
            surfaces: surfaces,
            spreads: [],
            usesTwoPageSpread: false
        )

        XCTAssertEqual(sequence.pageCount, 3)
        XCTAssertEqual(sequence.leafIndexes(forSelectionIndex: 1), [1])
        XCTAssertEqual(sequence.selectionIndex(forLeafIndexes: [2]), 2)
        XCTAssertEqual(sequence.leaves.map(\.surfaceIndex), [0, 1, 2])
    }

    func testPageCurlSequenceReversesPhysicalBookOrderForRightToLeftDirection() {
        let surfaces = makePageCurlSurfaces(count: 3)
        let sequence = NovelReaderPagedPageCurlSequence(
            surfaces: surfaces,
            spreads: [],
            usesTwoPageSpread: false,
            pageTurnDirection: .rightToLeft
        )

        XCTAssertEqual(sequence.pageCount, 3)
        XCTAssertEqual(sequence.leafIndexes(forSelectionIndex: 0), [2])
        XCTAssertEqual(sequence.leafIndexes(forSelectionIndex: 2), [0])
        XCTAssertEqual(sequence.selectionIndex(forLeafIndexes: [0]), 2)
        XCTAssertEqual(sequence.leaves.map(\.surfaceIndex), [2, 1, 0])
    }

    func testPageCurlSequenceMapsTwoPageSpreadsAndBlankTail() {
        let surfaces = makePageCurlSurfaces(count: 3)
        let spreads = [
            NovelReaderPresentationSpread(
                index: 0,
                leftSurfaceIndex: 0,
                leftSurfaceIdentity: surfaces[0].identity,
                rightSurfaceIndex: 1,
                rightSurfaceIdentity: surfaces[1].identity,
                chapterTitle: nil
            ),
            NovelReaderPresentationSpread(
                index: 1,
                leftSurfaceIndex: 2,
                leftSurfaceIdentity: surfaces[2].identity,
                rightSurfaceIndex: nil,
                rightSurfaceIdentity: nil,
                chapterTitle: nil
            )
        ]
        let sequence = NovelReaderPagedPageCurlSequence(
            surfaces: surfaces,
            spreads: spreads,
            usesTwoPageSpread: true
        )

        XCTAssertEqual(sequence.pageCount, 2)
        XCTAssertEqual(sequence.leafIndexes(forSelectionIndex: 1), [2, 3])
        XCTAssertEqual(sequence.selectionIndex(forLeafIndexes: [3]), 1)
        XCTAssertEqual(sequence.leaves.map(\.surfaceIndex), [0, 1, 2, nil])
    }

    func testPageCurlSequenceReversesTwoPageSpreadOrderForRightToLeftDirection() {
        let surfaces = makePageCurlSurfaces(count: 3)
        let spreads = [
            NovelReaderPresentationSpread(
                index: 0,
                leftSurfaceIndex: 0,
                leftSurfaceIdentity: surfaces[0].identity,
                rightSurfaceIndex: 1,
                rightSurfaceIdentity: surfaces[1].identity,
                chapterTitle: nil
            ),
            NovelReaderPresentationSpread(
                index: 1,
                leftSurfaceIndex: 2,
                leftSurfaceIdentity: surfaces[2].identity,
                rightSurfaceIndex: nil,
                rightSurfaceIdentity: nil,
                chapterTitle: nil
            )
        ]
        let sequence = NovelReaderPagedPageCurlSequence(
            surfaces: surfaces,
            spreads: spreads,
            usesTwoPageSpread: true,
            pageTurnDirection: .rightToLeft
        )

        XCTAssertEqual(sequence.pageCount, 2)
        XCTAssertEqual(sequence.leafIndexes(forSelectionIndex: 0), [2, 3])
        XCTAssertEqual(sequence.leafIndexes(forSelectionIndex: 1), [0, 1])
        XCTAssertEqual(sequence.selectionIndex(forLeafIndexes: [0]), 1)
        XCTAssertEqual(sequence.leaves.map(\.surfaceIndex), [2, nil, 0, 1])
    }

    func testPageCurlSequenceProvidesBlankControllersForEmptyContent() {
        let singlePageSequence = NovelReaderPagedPageCurlSequence(
            surfaces: [],
            spreads: [],
            usesTwoPageSpread: false
        )
        let spreadSequence = NovelReaderPagedPageCurlSequence(
            surfaces: [],
            spreads: [],
            usesTwoPageSpread: true
        )

        XCTAssertEqual(singlePageSequence.pageCount, 1)
        XCTAssertEqual(singlePageSequence.leafIndexes(forSelectionIndex: 0), [0])
        XCTAssertEqual(singlePageSequence.leaves.map(\.surfaceIndex), [nil])

        XCTAssertEqual(spreadSequence.pageCount, 1)
        XCTAssertEqual(spreadSequence.leafIndexes(forSelectionIndex: 0), [0, 1])
        XCTAssertEqual(spreadSequence.leaves.map(\.surfaceIndex), [nil, nil])
    }

    func testPagedPageTurnVisualMetricsFadeOverlayAsPageApproachesRest() {
        let start = ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: 201,
            pageWidth: 100,
            pageCount: 5,
            restingPageIndex: 2
        )
        let halfway = ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: 250,
            pageWidth: 100,
            pageCount: 5,
            restingPageIndex: 2
        )
        let completed = ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: 300,
            pageWidth: 100,
            pageCount: 5,
            restingPageIndex: 2
        )

        XCTAssertEqual(start?.overlayAlpha ?? 0, ReaderPagedPageTurnPresentation.maxOverlayAlpha * 0.99, accuracy: 0.001)
        XCTAssertEqual(halfway?.overlayAlpha ?? 0, ReaderPagedPageTurnPresentation.maxOverlayAlpha * 0.5, accuracy: 0.001)
        XCTAssertNil(completed)
    }

    func testPagedPageTurnVisualMetricsIdentifyNextAndPreviousPages() throws {
        let next = try XCTUnwrap(ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: 250,
            pageWidth: 100,
            pageCount: 5,
            restingPageIndex: 2
        ))
        let previous = try XCTUnwrap(ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: 150,
            pageWidth: 100,
            pageCount: 5,
            restingPageIndex: 2
        ))

        XCTAssertEqual(next.roundedPageIndex, 2)
        XCTAssertEqual(next.maskedPageIndex, 3)
        XCTAssertEqual(next.cornerRadius, ReaderPagedPageTurnPresentation.fallbackPageCornerRadius)
        XCTAssertTrue(next.isActive)
        XCTAssertEqual(previous.roundedPageIndex, 2)
        XCTAssertEqual(previous.maskedPageIndex, 1)
        XCTAssertTrue(previous.isActive)
    }

    func testPagedPageTurnVisualMetricsStayInactiveAtRestAndBoundaries() {
        XCTAssertNil(ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: 200,
            pageWidth: 100,
            pageCount: 5,
            restingPageIndex: 2
        ))
        XCTAssertNil(ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: -20,
            pageWidth: 100,
            pageCount: 5,
            restingPageIndex: 0
        ))
        XCTAssertNil(ReaderPagedPageTurnPresentation.metrics(
            contentOffsetX: 420,
            pageWidth: 100,
            pageCount: 5,
            restingPageIndex: 4
        ))
    }

    func testSwiftUIViewUpdateCallbackSchedulerDefersCallbacksDuringViewUpdate() {
        let scheduler = SwiftUIViewUpdateCallbackScheduler()
        var events: [String] = []

        scheduler.publish {
            events.append("immediate")
        }

        XCTAssertEqual(events, ["immediate"])

        let deferredCallback = expectation(description: "Deferred callback")
        scheduler.performViewUpdate {
            scheduler.publish {
                events.append("deferred")
                deferredCallback.fulfill()
            }
            XCTAssertEqual(events, ["immediate"])
        }

        XCTAssertEqual(events, ["immediate"])
        scheduler.publish {
            events.append("queued-after-update")
        }
        XCTAssertEqual(events, ["immediate"])
        wait(for: [deferredCallback], timeout: 1)
        XCTAssertEqual(events, ["immediate", "deferred", "queued-after-update"])
    }

    func testNovelReadingPositionDisplayFailureDoesNotPublishUIKitOrEstimatedFallback() throws {
        let text = String(repeating: "Novel Reading Position must not advance through fallback display. ", count: 12)
        let document = NovelReaderProjection(
            threadID: "124",
            view: 1,
            maxView: 1,
            segments: [.text(text, chapterTitle: "第一章")]
        )

        XCTAssertThrowsError(
            try NovelTextLayout.layout(
                document: document,
                settings: NovelReaderAppearanceSettings(readingMode: .paged),
                layout: NovelReaderLayout(width: 320, height: 568),
                viewportSurfaceLayout: { _, _, _ in [] }
            )
        ) { error in
            XCTAssertEqual(error as? NovelTextLayoutFailure, .textKitIndexing)
        }
    }
}

private func makePageCurlSurfaces(count: Int) -> [NovelReaderSurface] {
    (0 ..< count).map { index in
        NovelReaderSurface(
            identity: NovelReaderSurfaceIdentity(generation: 1, ordinal: index),
            presentationIndex: index,
            kind: .text,
            documentView: 1,
            chapterTitle: nil,
            presentationSize: CGSize(width: 320, height: 480)
        )
    }
}

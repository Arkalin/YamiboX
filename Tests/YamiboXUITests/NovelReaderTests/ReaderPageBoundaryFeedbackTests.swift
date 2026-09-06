import CoreGraphics
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

#if os(iOS)
import UIKit

@MainActor
final class ReaderPageBoundaryFeedbackTests: XCTestCase {
    func testPagingDriverRoutesAcceptedAndRejectedAttemptsWithoutChangingSelection() {
        let driver = ReaderPagedPagingDriver()
        var turns: [Int] = []
        var rejections: [Int] = []
        var selections: [Int] = []
        var inputs = ReaderPagedPagingInputs(
            itemCount: 1,
            selectionIndex: 0,
            pagedTurnStyle: .quickFade,
            horizontalNavigationDirection: .leftSwipeAdvances,
            pagerIdentity: ReaderPagedPagerIdentity(
                visibleView: 1, surfaceCount: 1, spreadCount: 1, usesTwoPageSpread: false, layout: .zero
            ),
            scrollAnimationRequest: nil,
            canBoundaryPageTurn: { $0 > 0 },
            onSelectionChange: { selections.append($0) },
            onBoundaryPageTurn: { turns.append($0) },
            onBoundaryPageTurnRejected: { rejections.append($0) },
            onScrollAnimationRequestConsumed: { _ in },
            pageTurnRestingBackgroundColor: { _ in .clear },
            pageTurnBackgroundColor: { _, _ in .clear }
        )
        driver.publishBoundaryPageTurnIfPossible(-1, inputs: inputs)
        driver.publishBoundaryPageTurnIfPossible(1, inputs: inputs)
        XCTAssertEqual(turns, [1])
        XCTAssertEqual(rejections, [-1])
        XCTAssertTrue(selections.isEmpty)

        inputs.itemCount = 0
        driver.publishBoundaryPageTurnIfPossible(-1, inputs: inputs)
        inputs.itemCount = 3
        inputs.selectionIndex = 1
        driver.publishBoundaryPageTurnIfPossible(-1, inputs: inputs)
        XCTAssertEqual(rejections, [-1])
    }

    func testTerminalGestureDetectionDoesNotDependOnHavingAnAdjacentPage() {
        for direction in [ReaderPagedHorizontalNavigationDirection.leftSwipeAdvances, .rightSwipeAdvances] {
            let delta = ReaderPagedBoundaryPageTurn.boundaryDelta(
                selectionIndex: 0, itemCount: 1,
                translation: CGPoint(x: -80, y: 0), velocity: .zero,
                viewportWidth: 390, horizontalNavigationDirection: direction
            )
            XCTAssertEqual(delta, direction == .leftSwipeAdvances ? 1 : -1)
        }
        XCTAssertNil(ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: 0, itemCount: 1, translation: CGPoint(x: -20, y: 0),
            velocity: .zero, viewportWidth: 390
        ))
        XCTAssertNil(ReaderPagedBoundaryPageTurn.boundaryDelta(
            selectionIndex: 0, itemCount: 0, translation: CGPoint(x: -100, y: 0),
            velocity: .zero, viewportWidth: 390
        ))
    }

    func testVerticalPullRequiresThresholdAndOutwardDirection() {
        XCTAssertEqual(ReaderVerticalBoundaryAttempt.boundary(
            offsetY: -72, minOffsetY: 0, maxOffsetY: 800, translationY: 100
        ), .previous)
        XCTAssertEqual(ReaderVerticalBoundaryAttempt.boundary(
            offsetY: 872, minOffsetY: 0, maxOffsetY: 800, translationY: -100
        ), .next)
        XCTAssertNil(ReaderVerticalBoundaryAttempt.boundary(
            offsetY: -71, minOffsetY: 0, maxOffsetY: 800, translationY: 100
        ))
        XCTAssertNil(ReaderVerticalBoundaryAttempt.boundary(
            offsetY: -80, minOffsetY: 0, maxOffsetY: 800, translationY: -100
        ))
        XCTAssertNil(ReaderVerticalBoundaryAttempt.boundary(
            offsetY: 880, minOffsetY: 0, maxOffsetY: 800, translationY: 100
        ))
        // A zoomed viewport has a larger scroll range, not a terminal edge.
        XCTAssertNil(ReaderVerticalBoundaryAttempt.boundary(
            offsetY: 880, minOffsetY: 0, maxOffsetY: 1600, translationY: -100
        ))
        XCTAssertEqual(ReaderVerticalBoundaryAttempt.boundary(
            offsetY: 72, minOffsetY: 0, maxOffsetY: 0, translationY: -100
        ), .next)
    }
}
#endif

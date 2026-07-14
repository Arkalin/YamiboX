import XCTest
@testable import YamiboXUI

final class ForumHomeCarouselPeekLayoutTests: XCTestCase {
    func testWideContainerCapsCardWidthAndCentersWithSymmetricInsets() {
        // 13" iPad landscape content width (1366 minus the page's 16pt padding).
        let layout = ForumHomeCarouselPeekLayout(containerWidth: 1334)

        XCTAssertEqual(layout.cardWidth, ForumHomeCarouselPeekLayout.maxCardWidth)
        XCTAssertEqual(layout.sideInset, (1334 - ForumHomeCarouselPeekLayout.maxCardWidth) / 2)
        XCTAssertEqual(layout.cardWidth + 2 * layout.sideInset, 1334)
    }

    func testSideInsetLeavesRoomForNeighborPeekBeyondCardSpacing() {
        // iPad portrait content width; the visible sliver of the neighboring
        // banner is the inset minus the inter-card spacing.
        let layout = ForumHomeCarouselPeekLayout(containerWidth: 802)

        XCTAssertGreaterThan(layout.sideInset, ForumHomeCarouselPeekLayout.cardSpacing)
        XCTAssertEqual(layout.cardWidth + 2 * layout.sideInset, 802)
    }

    func testNarrowContainerShrinksCardToPreserveMinimumInset() {
        let layout = ForumHomeCarouselPeekLayout(containerWidth: 600)

        XCTAssertEqual(layout.sideInset, ForumHomeCarouselPeekLayout.minSideInset)
        XCTAssertEqual(layout.cardWidth, 600 - 2 * ForumHomeCarouselPeekLayout.minSideInset)
    }

    func testUnmeasuredContainerFallsBackToMaxCardWidth() {
        let unmeasured = ForumHomeCarouselPeekLayout(containerWidth: nil)
        XCTAssertEqual(unmeasured.cardWidth, ForumHomeCarouselPeekLayout.maxCardWidth)
        XCTAssertEqual(unmeasured.sideInset, ForumHomeCarouselPeekLayout.minSideInset)

        let degenerate = ForumHomeCarouselPeekLayout(containerWidth: 0)
        XCTAssertEqual(degenerate, unmeasured)
    }

    func testTinyContainerNeverProducesNegativeCardWidth() {
        let layout = ForumHomeCarouselPeekLayout(containerWidth: 50)

        XCTAssertEqual(layout.cardWidth, 0)
        XCTAssertEqual(layout.sideInset, ForumHomeCarouselPeekLayout.minSideInset)
    }
}

final class ForumHomeCarouselLoopTests: XCTestCase {
    func testSingleBannerDoesNotLoop() {
        XCTAssertEqual(ForumHomeCarouselLoop.loopCount(itemCount: 1), 1)
        XCTAssertEqual(ForumHomeCarouselLoop.middleLoopIndex(for: 0, itemCount: 1), 0)
        XCTAssertFalse(ForumHomeCarouselLoop.isCloneIndex(0, itemCount: 1))
        XCTAssertNil(ForumHomeCarouselLoop.recenteredIndex(from: 0, itemCount: 1))
    }

    func testTripledStripMarksOuterCopiesAsClones() {
        XCTAssertEqual(ForumHomeCarouselLoop.loopCount(itemCount: 3), 9)
        XCTAssertTrue(ForumHomeCarouselLoop.isCloneIndex(2, itemCount: 3))
        XCTAssertFalse(ForumHomeCarouselLoop.isCloneIndex(3, itemCount: 3))
        XCTAssertFalse(ForumHomeCarouselLoop.isCloneIndex(5, itemCount: 3))
        XCTAssertTrue(ForumHomeCarouselLoop.isCloneIndex(6, itemCount: 3))
    }

    func testRecenterSnapsClonesToCongruentMiddleIndex() {
        // Settling on the leading copy's last banner recenters to the middle
        // copy's last banner; middle-copy positions stay put.
        XCTAssertEqual(ForumHomeCarouselLoop.recenteredIndex(from: 2, itemCount: 3), 5)
        XCTAssertEqual(ForumHomeCarouselLoop.recenteredIndex(from: 6, itemCount: 3), 3)
        XCTAssertNil(ForumHomeCarouselLoop.recenteredIndex(from: 4, itemCount: 3))
    }

    func testRecenterResetsWhenStripShrinksUnderStalePosition() {
        XCTAssertEqual(ForumHomeCarouselLoop.recenteredIndex(from: 14, itemCount: 3), 3)
    }

    func testHopTargetRollsForwardAcrossTheWrap() {
        // Auto-advance from the last banner (middle copy, index 5) to
        // selection 0 must move forward into the trailing copy, not scroll
        // all the way back.
        XCTAssertEqual(ForumHomeCarouselLoop.hopTarget(from: 5, to: 0, itemCount: 3), 6)
    }

    func testHopTargetTakesShortestPathBackwards() {
        // Tapping the previous banner's dot goes one card back, not two
        // forward...
        XCTAssertEqual(ForumHomeCarouselLoop.hopTarget(from: 4, to: 0, itemCount: 3), 3)
        // ...and stays put when the selection is already showing.
        XCTAssertNil(ForumHomeCarouselLoop.hopTarget(from: 4, to: 1, itemCount: 3))
    }
}

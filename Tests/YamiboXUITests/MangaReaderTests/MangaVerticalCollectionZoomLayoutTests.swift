import CoreGraphics
import Testing
@testable import YamiboXUI

@Suite("MangaReaderTests: Vertical Collection Zoom Layout")
struct MangaVerticalCollectionZoomLayoutTests {
    @Test func doubleTapTargetTogglesBetweenMinimumAndTargetScale() {
        #expect(MangaVerticalCollectionZoomLayout.doubleTapTargetScale(from: 1) == 2)
        #expect(MangaVerticalCollectionZoomLayout.doubleTapTargetScale(from: 1.05) == 2)
        #expect(MangaVerticalCollectionZoomLayout.doubleTapTargetScale(from: 1.06) == 1)
        #expect(MangaVerticalCollectionZoomLayout.doubleTapTargetScale(from: 2) == 1)
    }

    @Test func scaleAndItemMetricsAreClamped() {
        #expect(MangaVerticalCollectionZoomLayout.clampedScale(0.2) == 1)
        #expect(MangaVerticalCollectionZoomLayout.clampedScale(2.5) == 2.5)
        #expect(MangaVerticalCollectionZoomLayout.clampedScale(8) == 4)
        #expect(MangaVerticalCollectionZoomLayout.itemWidth(viewportWidth: 390, zoomScale: 2) == 780)
        #expect(MangaVerticalCollectionZoomLayout.estimatedItemHeight(baseHeight: 560, zoomScale: 2) == 1_120)
    }

    @Test func zoomingInKeepsVisibleAnchorStable() {
        let offset = MangaVerticalCollectionZoomLayout.anchoredContentOffset(
            currentOffset: CGPoint(x: 20, y: 100),
            visibleAnchor: CGPoint(x: 100, y: 200),
            oldScale: 1,
            newScale: 2,
            targetContentSize: CGSize(width: 800, height: 2_400),
            viewportSize: CGSize(width: 400, height: 800)
        )

        #expect(offset == CGPoint(x: 140, y: 400))
    }

    @Test func zoomingOutKeepsVerticalAnchorStableAndClampsHorizontalOffset() {
        let offset = MangaVerticalCollectionZoomLayout.anchoredContentOffset(
            currentOffset: CGPoint(x: 140, y: 400),
            visibleAnchor: CGPoint(x: 100, y: 200),
            oldScale: 2,
            newScale: 1,
            targetContentSize: CGSize(width: 400, height: 1_200),
            viewportSize: CGSize(width: 400, height: 800)
        )

        #expect(offset == CGPoint(x: 0, y: 100))
    }

    @Test func anchoredOffsetIsClampedToContentEdges() {
        let offset = MangaVerticalCollectionZoomLayout.anchoredContentOffset(
            currentOffset: CGPoint(x: 350, y: 1_100),
            visibleAnchor: CGPoint(x: 380, y: 760),
            oldScale: 1,
            newScale: 2,
            targetContentSize: CGSize(width: 800, height: 1_400),
            viewportSize: CGSize(width: 400, height: 800),
            adjustedContentInset: MangaVerticalCollectionZoomInsets(top: 10, left: 20, bottom: 30, right: 40)
        )

        #expect(offset == CGPoint(x: 440, y: 630))
    }
}

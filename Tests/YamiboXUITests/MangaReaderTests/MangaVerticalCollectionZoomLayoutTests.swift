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

    @Test func baseGeometryUsesKnownRatiosAndExistingFallback() {
        let layout = MangaVerticalCollectionZoomLayout(
            pageIDs: ["a", "b"], width: 360, heightToWidthRatios: ["a": 2]
        )
        #expect(layout.frames == [
            CGRect(x: 0, y: 0, width: 360, height: 720),
            CGRect(x: 0, y: 720, width: 360, height: 500)
        ])
        #expect(layout.contentSize == CGSize(width: 360, height: 1220))
    }

    @Test func exactBoundariesDoNotCountOverscanOrAdjacentPages() {
        let layout = MangaVerticalCollectionZoomLayout(pageIDs: ["a", "b", "c"], width: 360)
        #expect(layout.indexes(intersecting: CGRect(x: 0, y: 500, width: 360, height: 500)) == 1..<2)
        #expect(layout.indexes(intersecting: CGRect(x: 0, y: -100, width: 360, height: 300)) == 0..<1)
        #expect(layout.indexes(intersecting: CGRect(x: 0, y: 2000, width: 360, height: 300)).isEmpty)
    }

    @Test(arguments: [20, 200])
    func virtualWindowIsBoundedIndependentlyOfChapterLength(count: Int) {
        let layout = MangaVerticalCollectionZoomLayout(pageIDs: (0..<count).map(String.init), width: 360)
        let visible = CGRect(x: 40, y: 3000, width: 180, height: 400)
        let window = layout.window(covering: visible)
        #expect(window == CGRect(x: 0, y: 2600, width: 360, height: 1200))
        #expect(layout.indexes(intersecting: window).count <= 4)
        #expect(layout.indexes(intersecting: visible).count == 1)
    }

    @Test func normalizedPageAnchorSurvivesEarlierHeightCorrectionAndRotation() throws {
        let original = MangaVerticalCollectionZoomLayout(pageIDs: ["a", "b"], width: 360)
        let anchor = try #require(original.anchor(at: CGPoint(x: 90, y: 750), viewportPoint: CGPoint(x: 100, y: 200)))
        #expect(anchor.pageID == "b")
        #expect(anchor.normalizedPoint == CGPoint(x: 0.25, y: 0.5))
        let corrected = MangaVerticalCollectionZoomLayout(
            pageIDs: ["a", "b"], width: 720, heightToWidthRatios: ["a": 2, "b": 3]
        )
        #expect(corrected.contentPoint(for: anchor) == CGPoint(x: 180, y: 2520))
    }
}

import CoreGraphics
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@Suite("MangaReaderTests: Paged Image Surface Layout")
struct MangaPagedImageSurfaceLayoutTests {
    @Test func zoomPolicyCentralizesSharedMangaPageZoomThresholds() {
        #expect(MangaPageZoomPolicy.minimumScale == 1)
        #expect(MangaPageZoomPolicy.doubleTapTargetScale == 2)
        #expect(MangaPageZoomPolicy.maximumScale == 4)
        #expect(MangaPageZoomPolicy.clampedScale(0.2) == 1)
        #expect(MangaPageZoomPolicy.clampedScale(2.5) == 2.5)
        #expect(MangaPageZoomPolicy.clampedScale(8) == 4)
        #expect(!MangaPageZoomPolicy.isActive(1.01))
        #expect(MangaPageZoomPolicy.isActive(1.02))
        #expect(!MangaPageZoomPolicy.isZoomedForDoubleTapReset(1.05))
        #expect(MangaPageZoomPolicy.isZoomedForDoubleTapReset(1.06))
    }

    @Test func centerTapHitTestingAcceptsOnlyMiddleThirdInsideBounds() {
        let bounds = CGRect(x: 20, y: 40, width: 360, height: 720)

        #expect(!MangaPagedCenterTapHitTesting.acceptsCenterTap(at: CGPoint(x: 139.9, y: 400), in: bounds))
        #expect(MangaPagedCenterTapHitTesting.acceptsCenterTap(at: CGPoint(x: 140, y: 400), in: bounds))
        #expect(MangaPagedCenterTapHitTesting.acceptsCenterTap(at: CGPoint(x: 260, y: 400), in: bounds))
        #expect(!MangaPagedCenterTapHitTesting.acceptsCenterTap(at: CGPoint(x: 260.1, y: 400), in: bounds))

        #expect(!MangaPagedCenterTapHitTesting.acceptsCenterTap(at: CGPoint(x: 200, y: 39.9), in: bounds))
        #expect(!MangaPagedCenterTapHitTesting.acceptsCenterTap(at: CGPoint(x: 200, y: 760), in: bounds))
        #expect(!MangaPagedCenterTapHitTesting.acceptsCenterTap(at: CGPoint(x: 379.9, y: 400), in: bounds))

        #expect(!MangaPagedCenterTapHitTesting.acceptsCenterTap(at: CGPoint(x: 200, y: 400), in: .zero))
        #expect(!MangaPagedCenterTapHitTesting.acceptsCenterTap(
            at: CGPoint(x: 200, y: 400),
            in: CGRect(x: 20, y: 40, width: 360, height: 0)
        ))
        #expect(ReaderPagedTapZone.zone(for: CGPoint(x: 140, y: 400), in: bounds) == .toggleChrome)
        #expect(ReaderPagedTapZone.zone(for: CGPoint(x: 260, y: 400), in: bounds) == .toggleChrome)
    }

    @Test func pageLongPressHitTestingAcceptsOnlyMiddleThirdOfLoadedImage() {
        let pageBounds = CGRect(x: 20, y: 40, width: 360, height: 720)
        let imageFrame = CGRect(x: 80, y: 100, width: 240, height: 600)

        #expect(!MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 139.9, y: 400),
            in: pageBounds,
            imageFrame: imageFrame
        ))
        #expect(MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 140, y: 400),
            in: pageBounds,
            imageFrame: imageFrame
        ))
        #expect(MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 260, y: 400),
            in: pageBounds,
            imageFrame: imageFrame
        ))
        #expect(!MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 260.1, y: 400),
            in: pageBounds,
            imageFrame: imageFrame
        ))
        #expect(!MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 200, y: 99.9),
            in: pageBounds,
            imageFrame: imageFrame
        ))
        #expect(!MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 200, y: 700.1),
            in: pageBounds,
            imageFrame: imageFrame
        ))
    }

    @Test func pageLongPressHitTestingScopesMiddleThirdToEachTwoPageSlot() {
        let leftSlot = CGRect(x: 0, y: 0, width: 300, height: 800)
        let rightSlot = CGRect(x: 300, y: 0, width: 300, height: 800)

        #expect(!MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 99.9, y: 400),
            in: leftSlot,
            imageFrame: leftSlot
        ))
        #expect(MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 100, y: 400),
            in: leftSlot,
            imageFrame: leftSlot
        ))
        #expect(MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 200, y: 400),
            in: leftSlot,
            imageFrame: leftSlot
        ))
        #expect(!MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 200.1, y: 400),
            in: leftSlot,
            imageFrame: leftSlot
        ))

        #expect(!MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 399.9, y: 400),
            in: rightSlot,
            imageFrame: rightSlot
        ))
        #expect(MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 400, y: 400),
            in: rightSlot,
            imageFrame: rightSlot
        ))
        #expect(MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 500, y: 400),
            in: rightSlot,
            imageFrame: rightSlot
        ))
        #expect(!MangaPageLongPressHitTesting.acceptsPageLongPress(
            at: CGPoint(x: 500.1, y: 400),
            in: rightSlot,
            imageFrame: rightSlot
        ))
    }

    @Test func pageLongPressHitFrameIntersectsWithDisplayedPagedImage() {
        let layout = MangaPagedImageSurfaceLayout(
            imageSize: CGSize(width: 800, height: 600),
            containerSize: CGSize(width: 400, height: 800),
            pageScaleMode: .fitWidth,
            initialHorizontalAlignment: .left,
            zoomScale: 1
        )

        #expect(layout.displayedImageFrame(forUserOffset: .zero) == CGRect(x: 0, y: 250, width: 400, height: 300))
        let thirdWidth = CGFloat(400) / 3
        #expect(MangaPageLongPressHitTesting.allowedFrame(
            in: CGRect(x: 0, y: 0, width: 400, height: 800),
            imageFrame: layout.displayedImageFrame(forUserOffset: .zero)
        ) == CGRect(x: thirdWidth, y: 250, width: thirdWidth, height: 300))
    }

    @Test func surfaceDragIntentRequiresDeliberateHorizontalUnzoomedDrag() {
        #expect(MangaPagedSurfaceDragIntent.unzoomedHorizontalTranslation(CGSize(width: 8, height: 0)) == nil)
        #expect(MangaPagedSurfaceDragIntent.unzoomedHorizontalTranslation(CGSize(width: 20, height: 24)) == nil)
        #expect(MangaPagedSurfaceDragIntent.unzoomedHorizontalTranslation(CGSize(width: -20, height: 4)) == CGSize(width: -20, height: 0))
        #expect(MangaPagedSurfaceDragIntent.unzoomedHorizontalTranslation(CGSize(width: 20, height: -4)) == CGSize(width: 20, height: 0))
    }

    @Test func surfaceDragIntentPreservesUnzoomedOffsetWhenInteractionDisables() {
        #expect(!MangaPagedSurfaceDragIntent.shouldResetOffsetWhenInteractionDisables(zoomScale: 1))
        #expect(!MangaPagedSurfaceDragIntent.shouldResetOffsetWhenInteractionDisables(zoomScale: 1.01))
        #expect(MangaPagedSurfaceDragIntent.shouldResetOffsetWhenInteractionDisables(zoomScale: 1.02))
    }

    @Test func surfaceEdgeInteractionMapsTapZonesToPhysicalEdges() {
        #expect(MangaPagedSurfaceEdgeInteraction.physicalEdge(forTapZone: .previous) == .left)
        #expect(MangaPagedSurfaceEdgeInteraction.physicalEdge(forTapZone: .next) == .right)
        #expect(MangaPagedSurfaceEdgeInteraction.physicalEdge(forTapZone: .toggleChrome) == nil)
    }

    @Test func surfaceEdgeInteractionMapsHorizontalPanTowardHiddenPhysicalEdge() {
        #expect(MangaPagedSurfaceEdgeInteraction.physicalEdge(horizontalVelocityX: -10, horizontalTranslationX: 200) == .right)
        #expect(MangaPagedSurfaceEdgeInteraction.physicalEdge(horizontalVelocityX: 10, horizontalTranslationX: -200) == .left)
        #expect(MangaPagedSurfaceEdgeInteraction.physicalEdge(horizontalVelocityX: 0, horizontalTranslationX: -20) == .right)
        #expect(MangaPagedSurfaceEdgeInteraction.physicalEdge(horizontalVelocityX: 0, horizontalTranslationX: 20) == .left)
        #expect(MangaPagedSurfaceEdgeInteraction.physicalEdge(horizontalVelocityX: 0, horizontalTranslationX: 0) == nil)
    }

    @Test func pageTurnPanPolicyDefersForActiveZoomBeforeHiddenEdge() {
        let hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge> = [.right]

        #expect(MangaPagedSurfaceEdgeInteraction.shouldRevealHiddenContent(on: .right, hiddenEdges: hiddenEdges))
        #expect(!MangaPagedSurfaceEdgeInteraction.shouldRevealHiddenContent(on: .left, hiddenEdges: hiddenEdges))
        #expect(MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: true,
            isZoomActive: true,
            hiddenEdges: [],
            physicalEdge: nil
        ))
        #expect(!MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: false,
            isZoomActive: true,
            hiddenEdges: [],
            physicalEdge: nil
        ))
        #expect(MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: true,
            isZoomActive: false,
            hiddenEdges: hiddenEdges,
            physicalEdge: .right
        ))
        #expect(!MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: false,
            isZoomActive: false,
            hiddenEdges: hiddenEdges,
            physicalEdge: .right
        ))
        #expect(!MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: true,
            isZoomActive: false,
            hiddenEdges: hiddenEdges,
            physicalEdge: .left
        ))
        #expect(!MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: true,
            isZoomActive: false,
            hiddenEdges: [],
            physicalEdge: .right
        ))
        #expect(!MangaPagedSurfaceEdgeInteraction.shouldDeferPageTurnPanToSurfaceContent(
            zoomEnabled: true,
            isZoomActive: false,
            hiddenEdges: hiddenEdges,
            physicalEdge: nil
        ))
    }

    @Test func fitWidthKeepsFixedPageSurfaceWithVerticalBlankSpace() {
        let layout = MangaPagedImageSurfaceLayout(
            imageSize: CGSize(width: 800, height: 600),
            containerSize: CGSize(width: 400, height: 800),
            pageScaleMode: .fitWidth,
            initialHorizontalAlignment: .left,
            zoomScale: 1
        )

        #expect(layout.fittedImageSize == CGSize(width: 400, height: 300))
        #expect(layout.contentSize == CGSize(width: 400, height: 300))
        #expect(layout.displayOffset(forUserOffset: .zero) == .zero)
        #expect(layout.clampedUserOffset(CGSize(width: 80, height: 80)) == .zero)
    }

    @Test func fitHeightInitialOverflowAlignmentFollowsInputEdge() {
        let left = Self.layout(initialHorizontalAlignment: .left)
        let right = Self.layout(initialHorizontalAlignment: .right)

        #expect(left.fittedImageSize == CGSize(width: 1200, height: 800))
        #expect(left.displayOffset(forUserOffset: .zero) == CGSize(width: 400, height: 0))
        #expect(right.displayOffset(forUserOffset: .zero) == CGSize(width: -400, height: 0))
    }

    @Test func fitHeightAdjacentEntryAlignmentShowsOppositeEdgeWhenReturningLeftToRight() {
        let forward = MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
            pageTurnDirection: .leftToRight,
            pageScaleMode: .fitHeight,
            currentPageIndex: 0,
            targetPageIndex: 1
        )
        let backward = MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
            pageTurnDirection: .leftToRight,
            pageScaleMode: .fitHeight,
            currentPageIndex: 1,
            targetPageIndex: 0
        )

        #expect(forward == .left)
        #expect(backward == .right)
        #expect(Self.layout(initialHorizontalAlignment: forward).displayOffset(forUserOffset: .zero) == CGSize(width: 400, height: 0))
        #expect(Self.layout(initialHorizontalAlignment: backward).displayOffset(forUserOffset: .zero) == CGSize(width: -400, height: 0))
    }

    @Test func fitHeightAdjacentEntryAlignmentShowsOppositeEdgeWhenReturningRightToLeft() {
        let forward = MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
            pageTurnDirection: .rightToLeft,
            pageScaleMode: .fitHeight,
            currentPageIndex: 0,
            targetPageIndex: 1
        )
        let backward = MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
            pageTurnDirection: .rightToLeft,
            pageScaleMode: .fitHeight,
            currentPageIndex: 1,
            targetPageIndex: 0
        )

        #expect(forward == .right)
        #expect(backward == .left)
        #expect(Self.layout(initialHorizontalAlignment: forward).displayOffset(forUserOffset: .zero) == CGSize(width: -400, height: 0))
        #expect(Self.layout(initialHorizontalAlignment: backward).displayOffset(forUserOffset: .zero) == CGSize(width: 400, height: 0))
    }

    @Test func initialEntryAlignmentUsesDefaultForNonAdjacentInitialAndFitWidthEntries() {
        #expect(
            MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
                pageTurnDirection: .leftToRight,
                pageScaleMode: .fitHeight,
                currentPageIndex: 4,
                targetPageIndex: 1
            ) == .left
        )
        #expect(
            MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
                pageTurnDirection: .leftToRight,
                pageScaleMode: .fitHeight,
                currentPageIndex: nil,
                targetPageIndex: 1
            ) == .left
        )
        #expect(
            MangaPagedImageSurfaceInitialHorizontalAlignment.enteringPage(
                pageTurnDirection: .leftToRight,
                pageScaleMode: .fitWidth,
                currentPageIndex: 1,
                targetPageIndex: 0
            ) == .left
        )
    }

    @Test func fitHeightHorizontalOverflowPanIsBoundedFromInitialAlignment() {
        let layout = MangaPagedImageSurfaceLayout(
            imageSize: CGSize(width: 1200, height: 800),
            containerSize: CGSize(width: 400, height: 800),
            pageScaleMode: .fitHeight,
            initialHorizontalAlignment: .left,
            zoomScale: 1
        )

        #expect(layout.clampedUserOffset(CGSize(width: 100, height: 0)) == .zero)
        #expect(layout.clampedUserOffset(CGSize(width: -1_000, height: 0)) == CGSize(width: -800, height: 0))
        #expect(layout.displayOffset(forUserOffset: CGSize(width: -800, height: 0)) == CGSize(width: -400, height: 0))
    }

    @Test func fitHeightReportsHiddenPhysicalEdgesFromInitialAlignment() {
        let leftToRight = Self.layout(initialHorizontalAlignment: .left)
        let rightToLeft = Self.layout(initialHorizontalAlignment: .right)

        #expect(!leftToRight.hasHiddenContent(on: .left, fromUserOffset: .zero))
        #expect(leftToRight.hasHiddenContent(on: .right, fromUserOffset: .zero))
        #expect(leftToRight.userOffsetRevealingContent(on: .right, fromUserOffset: .zero) == CGSize(width: -800, height: 0))
        #expect(leftToRight.userOffsetRevealingContent(on: .left, fromUserOffset: .zero) == nil)

        #expect(rightToLeft.hasHiddenContent(on: .left, fromUserOffset: .zero))
        #expect(!rightToLeft.hasHiddenContent(on: .right, fromUserOffset: .zero))
        #expect(rightToLeft.userOffsetRevealingContent(on: .left, fromUserOffset: .zero) == CGSize(width: 800, height: 0))
        #expect(rightToLeft.userOffsetRevealingContent(on: .right, fromUserOffset: .zero) == nil)
    }

    @Test func fitHeightCenteredOverflowCanRevealEitherPhysicalEdge() {
        let layout = MangaPagedImageSurfaceLayout(
            imageSize: CGSize(width: 1200, height: 800),
            containerSize: CGSize(width: 400, height: 800),
            pageScaleMode: .fitHeight,
            initialHorizontalAlignment: .left,
            zoomScale: 1
        )
        let centeredUserOffset = CGSize(width: -400, height: 0)

        #expect(layout.displayOffset(forUserOffset: centeredUserOffset) == .zero)
        #expect(layout.hasHiddenContent(on: .left, fromUserOffset: centeredUserOffset))
        #expect(layout.hasHiddenContent(on: .right, fromUserOffset: centeredUserOffset))
        #expect(layout.userOffsetRevealingContent(on: .left, fromUserOffset: centeredUserOffset) == .zero)
        #expect(layout.userOffsetRevealingContent(on: .right, fromUserOffset: centeredUserOffset) == CGSize(width: -800, height: 0))
    }

    @Test func nonOverflowingAndFitWidthSurfacesDoNotRevealPhysicalEdges() {
        let fitHeightWithoutOverflow = MangaPagedImageSurfaceLayout(
            imageSize: CGSize(width: 400, height: 800),
            containerSize: CGSize(width: 400, height: 800),
            pageScaleMode: .fitHeight,
            initialHorizontalAlignment: .left,
            zoomScale: 1
        )
        let fitWidth = MangaPagedImageSurfaceLayout(
            imageSize: CGSize(width: 1200, height: 800),
            containerSize: CGSize(width: 400, height: 800),
            pageScaleMode: .fitWidth,
            initialHorizontalAlignment: .right,
            zoomScale: 1
        )

        for edge in MangaPagedImageSurfaceHorizontalEdge.allCases {
            #expect(!fitHeightWithoutOverflow.hasHiddenContent(on: edge, fromUserOffset: .zero))
            #expect(fitHeightWithoutOverflow.userOffsetRevealingContent(on: edge, fromUserOffset: .zero) == nil)
            #expect(!fitWidth.hasHiddenContent(on: edge, fromUserOffset: .zero))
            #expect(fitWidth.userOffsetRevealingContent(on: edge, fromUserOffset: .zero) == nil)
        }
    }

    @Test func zoomedSurfacePanIsBoundedToScaledContent() {
        let layout = MangaPagedImageSurfaceLayout(
            imageSize: CGSize(width: 800, height: 1_200),
            containerSize: CGSize(width: 400, height: 800),
            pageScaleMode: .fitWidth,
            initialHorizontalAlignment: .left,
            zoomScale: 2
        )

        #expect(layout.contentSize == CGSize(width: 800, height: 1_200))
        #expect(layout.clampedUserOffset(CGSize(width: 600, height: -900)) == CGSize(width: 200, height: -200))
    }

    @Test func spreadZoomLayoutScalesWholeViewport() {
        let layout = MangaPagedSpreadSurfaceZoomLayout(
            containerSize: CGSize(width: 1_000, height: 700),
            zoomScale: 2
        )

        #expect(layout.contentSize == CGSize(width: 2_000, height: 1_400))
        #expect(layout.clampedUserOffset(CGSize(width: 900, height: -500)) == CGSize(width: 500, height: -350))
        #expect(layout.displayOffset(forUserOffset: CGSize(width: -600, height: 0)) == CGSize(width: -500, height: 0))
    }

    @Test func spreadZoomAnchorUsesWholeViewportCoordinates() {
        let layout = MangaPagedSpreadSurfaceZoomLayout(
            containerSize: CGSize(width: 1_000, height: 700),
            zoomScale: 2
        )

        #expect(layout.userOffsetAnchoring(CGPoint(x: 750, y: 350)) == CGSize(width: -500, height: 0))
        #expect(layout.userOffsetAnchoring(CGPoint(x: 500, y: 525)) == CGSize(width: 0, height: -350))
        #expect(layout.userOffsetAnchoring(CGPoint(x: 1_400, y: 350)) == .zero)
    }

    @Test func spreadZoomReportsHiddenPhysicalEdges() {
        let layout = MangaPagedSpreadSurfaceZoomLayout(
            containerSize: CGSize(width: 1_000, height: 700),
            zoomScale: 2
        )

        #expect(layout.hasHiddenContent(on: .left, fromUserOffset: .zero))
        #expect(layout.hasHiddenContent(on: .right, fromUserOffset: .zero))
        #expect(layout.userOffsetRevealingContent(on: .left, fromUserOffset: .zero) == CGSize(width: 500, height: 0))
        #expect(layout.userOffsetRevealingContent(on: .right, fromUserOffset: .zero) == CGSize(width: -500, height: 0))
        #expect(!layout.hasHiddenContent(on: .left, fromUserOffset: CGSize(width: 500, height: 0)))
    }

    private static func layout(
        initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment
    ) -> MangaPagedImageSurfaceLayout {
        MangaPagedImageSurfaceLayout(
            imageSize: CGSize(width: 1200, height: 800),
            containerSize: CGSize(width: 400, height: 800),
            pageScaleMode: .fitHeight,
            initialHorizontalAlignment: initialHorizontalAlignment,
            zoomScale: 1
        )
    }
}

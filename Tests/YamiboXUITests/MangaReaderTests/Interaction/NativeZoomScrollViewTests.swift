#if os(iOS)
import Testing
import UIKit
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Native reader zoom geometry", .serialized)
struct NativeZoomScrollViewTests {
    @Test func touchStoppingNativeMomentumCannotBecomeChromeTap() {
        let view = MotionView()
        var now: CFTimeInterval = 10
        view.currentTime = { now }
        #expect(view.acceptsDiscreteTouch)
        view.simulatedDeceleration = true
        view.scrollViewDidScroll(view)
        #expect(!view.acceptsDiscreteTouch)
        view.simulatedDeceleration = false
        now += 0.1
        #expect(!view.acceptsDiscreteTouch)
        now += 0.3
        #expect(view.acceptsDiscreteTouch)
    }

    private final class MotionView: NativeZoomScrollView {
        var simulatedDeceleration = false
        override var isDecelerating: Bool { simulatedDeceleration }
    }

    @Test func nativePhysicsAndStableContentHost() {
        let view = NativeZoomScrollView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.configureGeometry(contentSize: CGSize(width: 400, height: 6000), maximumFactor: 4)
        let content = view.zoomContentView
        #expect(view.delegate === view)
        #expect(view.viewForZooming(in: view) === content)
        #expect(view.bounces && view.bouncesZoom)
        #expect(view.decelerationRate == .normal)

        view.zoom(factor: 2, centeredAt: CGPoint(x: 150, y: 1600), animated: false)
        #expect(view.normalizedZoomFactor == 2)
        #expect(abs(view.snapshot.visibleRect.midX - 150) < 0.01)
        #expect(abs(view.snapshot.visibleRect.midY - 1600) < 0.01)
        view.configureGeometry(contentSize: CGSize(width: 400, height: 6000), maximumFactor: 4)
        #expect(view.zoomContentView === content)
        #expect(view.normalizedZoomFactor == 2)

        view.zoom(factor: 20, centeredAt: .zero, animated: false)
        #expect(view.normalizedZoomFactor == 4)
        #expect(view.contentOffset == .zero)
        view.resetZoom(animated: false)
        #expect(view.normalizedZoomFactor == 1)
    }

    @Test func croppedBaseImageCanRestAtEitherEdgeWithoutChangingFit() {
        let view = NativeZoomScrollView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.configureGeometry(contentSize: CGSize(width: 1000, height: 800), maximumFactor: 4)
        view.place(contentPoint: .zero, at: .zero)
        #expect(view.contentOffset.x == 0)
        view.place(contentPoint: CGPoint(x: 1000, y: 0), at: CGPoint(x: 400, y: 0))
        #expect(view.contentOffset.x == 600)
        #expect(view.normalizedZoomFactor == 1)
    }

    @Test func imageBrowserKeepsOwnScalePolicyAndAnimationFrameDoesNotResetGeometry() {
        let view = ImageBrowserZoomScrollView()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
        }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.configure(image: image)
        view.layoutIfNeeded()
        #expect(view.minimumZoomScale == 0.5)
        #expect(view.maximumZoomScale == 2.5)
        #expect(!view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
        view.zoom(factor: 2.6, centeredAt: CGPoint(x: 450, y: 700), animated: false)
        let before = view.snapshot
        view.displayFrame(UIImage())
        view.layoutIfNeeded()
        #expect(view.snapshot.factor == before.factor)
        #expect(view.snapshot.visibleRect == before.visibleRect)
        #expect(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))

        view.frame.size = CGSize(width: 600, height: 500)
        view.layoutIfNeeded()
        #expect(abs(view.normalizedZoomFactor - 2.6) < 0.001)
        #expect(abs(view.snapshot.visibleRect.midX - before.visibleRect.midX) < 2)
        #expect(abs(view.snapshot.visibleRect.midY - before.visibleRect.midY) < 2)
        view.resetZoom(animated: false)
        #expect(view.normalizedZoomFactor == 1)
    }
}

@MainActor @Suite("Native vertical manga viewport", .serialized)
struct MangaVerticalNativeViewportTests {
    @Test(arguments: [CGFloat(1), 2, 4])
    func chromeUpdatesPreserveZoomOffsetContainerAndRecognizers(factor: CGFloat) {
        let fixture = Fixture(count: 20)
        defer { fixture.owner.dismantle() }
        let view = fixture.view!
        view.zoom(factor: factor, centeredAt: CGPoint(x: 180, y: 3000), animated: false)
        view.place(contentPoint: CGPoint(x: 120, y: 3100), at: CGPoint(x: 120, y: 250))
        let before = view.snapshot
        let revision = fixture.owner.layoutRevision
        let pinch = view.pinchGestureRecognizer
        let pan = view.panGestureRecognizer
        for chrome in [true, false, true, false] {
            fixture.owner.parent = fixture.viewport(chrome: chrome)
            fixture.owner.updateContentIfNeeded(in: view)
            view.layoutIfNeeded()
            #expect(view.snapshot == before)
            #expect(fixture.owner.layoutRevision == revision)
            #expect(view.pinchGestureRecognizer === pinch)
            #expect(view.panGestureRecognizer === pan)
            #expect(view.gestureRecognizerShouldBegin(pinch!))
            #expect(view.gestureRecognizerShouldBegin(pan))
        }
    }

    @Test(arguments: [20, 200])
    func mountedCellsAndLayoutWorkStayBoundedDuringNativeZoom(count: Int) {
        let fixture = Fixture(count: count)
        defer { fixture.owner.dismantle() }
        let view = fixture.view!
        view.place(contentPoint: CGPoint(x: 0, y: 3500), at: .zero)
        let revision = fixture.owner.layoutRevision
        for factor in [CGFloat(1), 2, 4, 2, 1] {
            view.zoom(factor: factor, centeredAt: CGPoint(x: 200, y: 4000), animated: false)
            view.layoutIfNeeded()
            #expect(fixture.owner.layoutRevision == revision)
            #expect(view.collectionView.frame.height <= 3 * view.bounds.height + 1)
            #expect(view.collectionView.visibleCells.count <= 7)
            #expect(!view.collectionView.visibleCells.isEmpty)
            #expect(fixture.owner.visiblePageIndexes().count < view.collectionView.visibleCells.count)
        }
    }

    @Test func batchedRatioCorrectionsAndRotationRestoreThePageAnchor() async throws {
        let fixture = Fixture(count: 20)
        defer { fixture.owner.dismantle() }
        let view = fixture.view!
        view.zoom(factor: 2, centeredAt: CGPoint(x: 200, y: 3500), animated: false)
        let before = view.snapshot
        let anchor = try #require(fixture.owner.logicalLayout.anchor(
            at: CGPoint(x: before.visibleRect.midX, y: before.visibleRect.midY),
            viewportPoint: CGPoint(x: view.bounds.width / 2, y: view.bounds.height / 2)
        ))
        let revision = fixture.owner.layoutRevision
        fixture.owner.recordHeightToWidthRatio(3, for: fixture.pages[0].id)
        fixture.owner.recordHeightToWidthRatio(2, for: fixture.pages[1].id)
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.owner.layoutRevision == revision + 1)
        let point = try #require(fixture.owner.logicalLayout.contentPoint(for: anchor))
        #expect(abs(view.snapshot.visibleRect.midX - point.x) < 2)
        #expect(abs(view.snapshot.visibleRect.midY - point.y) < 2)
        #expect(view.normalizedZoomFactor == 2)

        view.frame.size = CGSize(width: 800, height: 400)
        view.layoutIfNeeded()
        let rotatedPoint = try #require(fixture.owner.logicalLayout.contentPoint(for: anchor))
        #expect(abs(view.snapshot.visibleRect.midX - rotatedPoint.x) < 2)
        #expect(abs(view.snapshot.visibleRect.midY - rotatedPoint.y) < 2)
        #expect(view.normalizedZoomFactor == 2)
    }

    @Test func disablingZoomResetsButDoesNotRebuildChapterGeometry() {
        let fixture = Fixture(count: 20)
        defer { fixture.owner.dismantle() }
        fixture.view.zoom(factor: 4, centeredAt: CGPoint(x: 200, y: 3500), animated: false)
        let revision = fixture.owner.layoutRevision
        fixture.owner.parent = fixture.viewport(chrome: true, zoom: false)
        fixture.owner.updateContentIfNeeded(in: fixture.view)
        #expect(fixture.view.normalizedZoomFactor == 1)
        #expect(fixture.view.maximumZoomScale == 1)
        #expect(fixture.view.permitsPinch?() == false)
        if let pinch = fixture.view.pinchGestureRecognizer {
            #expect(!fixture.view.gestureRecognizerShouldBegin(pinch))
        }
        #expect(fixture.owner.layoutRevision == revision)
    }

    @MainActor private final class Fixture {
        let pages: [MangaReaderPageProjection]
        let loader: MangaReaderPageImageLoader
        var owner: MangaVerticalCollectionViewport.Coordinator!
        var view: MangaVerticalNativeViewport!

        init(count: Int) {
            pages = (0..<count).map { index in
                MangaReaderPageProjection(tid: "native-zoom", ownerPostID: "1", chapterTitle: "Fixture",
                    imageURL: URL(fileURLWithPath: "/native-zoom-test-\(index).png"),
                    sourceIdentity: MangaReaderProjectionSourceIdentity(tid: "native-zoom", authorID: nil, view: 1),
                    globalIndex: index, localIndex: index, chapterPageCount: count)
            }
            loader = MangaReaderPageImageLoader(imageSource: { YamiboImageSource(url: $0.imageURL) },
                uiImagePipeline: YamiboUIImagePipeline(core: YamiboImagePipeline()))
            let viewport = viewport(chrome: false)
            owner = viewport.makeCoordinator()
            view = viewport.makeViewportView(coordinator: owner)
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            owner.updateContentIfNeeded(in: view)
            view.layoutIfNeeded()
        }

        func viewport(chrome: Bool, zoom: Bool = true) -> MangaVerticalCollectionViewport {
            MangaVerticalCollectionViewport(pages: pages, currentPageIndex: 0, viewportPlacement: nil,
                controlScrollStep: nil, imageLoader: loader, isChromeVisible: chrome, zoomEnabled: zoom,
                likedPageIDs: [], onCurrentPageChange: { _ in }, onControlScrollEdgeReached: { _ in },
                onPageLongPress: { _ in }, onTap: {})
        }
    }
}
#endif

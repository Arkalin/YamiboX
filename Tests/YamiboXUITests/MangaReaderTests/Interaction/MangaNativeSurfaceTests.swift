#if os(iOS)
import Testing
import UIKit
@testable import YamiboXUI

@MainActor @Suite("Native paged image and spread", .serialized)
struct MangaNativeSurfaceTests {
    @Test(arguments: [false, true])
    func rotationUsesOldBaseCoordinatesRegardlessOfRepresentableUpdateOrder(updateFirst: Bool) async {
        let runtime = MangaSurfaceRuntime()
        let view = MangaNativeSurfaceView()
        let landscape = CGSize(width: 1000, height: 700)
        view.frame = CGRect(origin: .zero, size: landscape)
        view.configure(runtime: runtime, configuration: MangaInteractionConfiguration(),
            geometry: .spread(viewport: landscape), imageLoaded: true)
        view.layoutIfNeeded()
        view.zoom(factor: 2, centeredAt: CGPoint(x: 750, y: 350), animated: false)
        await settle()
        let before = view.snapshot
        for size in [CGSize(width: 700, height: 1000), landscape] {
            if updateFirst {
                view.configure(runtime: runtime, configuration: MangaInteractionConfiguration(),
                    geometry: .spread(viewport: size), imageLoaded: true)
            }
            view.frame.size = size
            if !updateFirst {
                view.configure(runtime: runtime, configuration: MangaInteractionConfiguration(),
                    geometry: .spread(viewport: size), imageLoaded: true)
            }
            view.layoutIfNeeded()
            await settle()
            #expect(abs(view.contentOffset.x - size.width) < 1)
        }
        #expect(abs(view.snapshot.visibleRect.midX - before.visibleRect.midX) < 1)
        #expect(abs(view.snapshot.visibleRect.midY - before.visibleRect.midY) < 1)
        #expect(view.normalizedZoomFactor == 2)
        view.detach()
    }

    @Test(arguments: [CGFloat(1), 2, 4], [false, true])
    func chromeKeepsNativeStateAndImageAdmission(factor: CGFloat, spread: Bool) async {
        let runtime = MangaSurfaceRuntime()
        let view = MangaNativeSurfaceView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let geometry: MangaSurfaceGeometry = spread ? .spread(viewport: view.bounds.size)
            : .image(size: CGSize(width: 1200, height: 800), viewport: view.bounds.size, fit: .fitHeight, alignment: .right)
        view.configure(runtime: runtime, configuration: MangaInteractionConfiguration(), geometry: geometry, imageLoaded: true)
        view.layoutIfNeeded()
        await settle()
        view.zoom(factor: factor, centeredAt: CGPoint(x: spread ? 200 : 700, y: 400), animated: false)
        await settle()
        let before = view.snapshot
        let generation = runtime.generation
        let pan = view.panGestureRecognizer
        let pinch = view.pinchGestureRecognizer
        for chrome in [true, false, true] {
            view.configure(runtime: runtime, configuration: MangaInteractionConfiguration(chromeVisible: chrome),
                           geometry: geometry, imageLoaded: true)
            await settle()
            #expect(view.snapshot == before)
            #expect(runtime.generation == generation)
            #expect(runtime.transform.scale == factor)
            #expect(view.panGestureRecognizer === pan)
            #expect(view.pinchGestureRecognizer === pinch)
            #expect(view.permitsPinch?() == true)
            #expect(runtime.decision(.doubleTap(.zero)) == (chrome ? .toggleChrome : .zoom(.zero)))
            if factor > 1 {
                #expect(runtime.decision(.pan(translation: CGSize(width: -10, height: 0), velocity: .zero)) == .panImage)
            }
        }
        view.detach()
    }

    @Test func zoomCentersTheTappedContentPointAndRevealUsesNativeOffset() async {
        let runtime = MangaSurfaceRuntime()
        let view = MangaNativeSurfaceView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let geometry = MangaSurfaceGeometry.image(size: CGSize(width: 1200, height: 800),
            viewport: view.bounds.size, fit: .fitHeight, alignment: .left)
        view.configure(runtime: runtime, configuration: MangaInteractionConfiguration(), geometry: geometry, imageLoaded: true)
        view.layoutIfNeeded()
        await settle()
        #expect(view.contentOffset.x == 0)
        view.applyNative(.reveal(.right), animated: false)
        await settle()
        #expect(view.contentOffset.x == 800)
        #expect(!runtime.hiddenEdges.contains(.right))
        view.applyNative(.zoom(CGPoint(x: 180, y: 430)), animated: false)
        await settle()
        #expect(view.normalizedZoomFactor == 2)
        #expect(abs(view.snapshot.visibleRect.midX - 980) < 2)
        #expect(abs(view.snapshot.visibleRect.midY - 430) < 2)
        view.detach()
    }

    @Test func replacementRejectsOldCallbacksAndNavigationResetsOnlyCurrentHost() async {
        let runtime = MangaSurfaceRuntime()
        let first = MangaNativeSurfaceView()
        let second = MangaNativeSurfaceView()
        for view in [first, second] {
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            view.configure(runtime: runtime, configuration: MangaInteractionConfiguration(),
                geometry: .spread(viewport: view.bounds.size), imageLoaded: true)
            view.layoutIfNeeded()
        }
        second.zoom(factor: 2, centeredAt: CGPoint(x: 200, y: 400), animated: false)
        first.configure(runtime: runtime, configuration: MangaInteractionConfiguration(chromeVisible: true),
            geometry: .spread(viewport: first.bounds.size), imageLoaded: false)
        first.zoom(factor: 4, centeredAt: CGPoint(x: 200, y: 400), animated: false)
        first.detach()
        await settle()
        #expect(runtime.transform.scale == 2)
        #expect(runtime.imageLoaded)
        #expect(!runtime.configuration.chromeVisible)
        runtime.invalidate(reset: true)
        await settle()
        #expect(second.normalizedZoomFactor == 1)
        #expect(runtime.transform.scale == 1)
        second.detach()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(15))
    }
}
#endif

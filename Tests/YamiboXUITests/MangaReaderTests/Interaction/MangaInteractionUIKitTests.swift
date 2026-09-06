#if os(iOS)
import SwiftUI
import UIKit
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Paged interaction UIKit integration")
struct MangaInteractionUIKitTests {
    @Test(arguments: [false, true], [false, true])
    func mountedBackendsRouteExternalBoundaryExactlyOnce(curl: Bool, canNavigate: Bool) throws {
        let page = try makePipelinePage()
        let plan = MangaPagedReadingPlan(pages: [page], currentPageIndex: 0)
        let bridge = MangaPagedControlPageTurnBridge()
        var boundaries: [Int] = []
        var rejections: [Int] = []
        let loader = MangaReaderPageImageLoader(imageSource: { _ in
            YamiboImageSource(url: URL(fileURLWithPath: "/nonexistent/manga-interaction-test.png"))
        })
        let settings = MangaReaderSettings(readingMode: .paged)
        let root: AnyView
        if curl {
            root = AnyView(MangaPagedPageCurlReaderViewport(plan: plan, viewportPlacement: nil, settings: settings,
                imageLoader: loader, isChromeVisible: false, zoomEnabled: true, likedPageIDs: [],
                controlPageTurnBridge: bridge, onCurrentPageChange: { _ in }, canBoundaryPageTurn: { _ in canNavigate },
                onBoundaryPageTurn: { boundaries.append($0) }, onBoundaryPageTurnRejected: { rejections.append($0) },
                onPageLongPress: { _ in }, onTap: {}))
        } else {
            root = AnyView(MangaPagedReaderViewport(plan: plan, viewportPlacement: nil, settings: settings,
                imageLoader: loader, isChromeVisible: false, zoomEnabled: true, likedPageIDs: [],
                controlPageTurnBridge: bridge, onCurrentPageChange: { _ in }, canBoundaryPageTurn: { _ in canNavigate },
                onBoundaryPageTurn: { boundaries.append($0) }, onBoundaryPageTurnRejected: { rejections.append($0) },
                onPageLongPress: { _ in }, onTap: {}))
        }
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(bridge.route != nil)
        bridge.requestPageTurn(1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        bridge.requestPageTurn(-1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(boundaries == (canNavigate ? [1, -1] : []))
        #expect(rejections == (canNavigate ? [] : [1, -1]))
    }

    @Test func nativeAdmissionPreservesOriginalDelegateAndDetaches() {
        let original = OriginalDelegate()
        let pan = UIPanGestureRecognizer()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.addGestureRecognizer(pan)
        pan.delegate = original
        let admission = MangaNativePanAdmission(pan, permits: { _ in true })
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == true)
        #expect(original.calls == 1)
        admission.permits = { _ in false }
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false)
        #expect(original.calls == 1)
        admission.detach()
        #expect(pan.delegate === original)
    }

    @Test func installedSurfaceRecognizersUsePolicyAndScopedRelationships() throws {
        let runtime = MangaSurfaceRuntime()
        runtime.configure(MangaInteractionConfiguration(zoomEnabled: false),
            geometry: .image(size: CGSize(width: 800, height: 800), viewport: CGSize(width: 400, height: 800),
                fit: .fitHeight, alignment: .left), imageLoaded: true)
        let registry = MangaSurfaceGestureRegistry()
        let input = MangaSurfaceGestureInput(runtime: runtime, registry: registry, role: .pan)
        let pan = try #require(input.makeRecognizer() as? UIPanGestureRecognizer)
        let pinchInput = MangaSurfaceGestureInput(runtime: runtime, registry: registry, role: .pinch)
        let pinch = pinchInput.makeRecognizer()
        let view = UIView(frame: CGRect(x: 40, y: 80, width: 400, height: 800))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        pan.setTranslation(CGPoint(x: -2, y: 0), in: view)
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == true)
        pan.setTranslation(CGPoint(x: 2, y: 0), in: view)
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: pinch) == true)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: UIPinchGestureRecognizer()) == false)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer()) == false)
        runtime.configure(MangaInteractionConfiguration(chromeVisible: true), geometry: runtime.geometry, imageLoaded: true)
        input.update(pan)
        #expect(!pan.isEnabled)
    }

    @Test(arguments: [CGFloat(400), 600, 800, 1200])
    func productionViewInstallsLongPressInFixedViewport(imageWidth: CGFloat) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: imageWidth, height: 800)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: imageWidth, height: 800))
        }
        let surface = MangaSurfaceAttachment()
        let root = MangaPagedReaderScaledImage(image: image, pageID: "layout", pageScaleMode: .fitHeight,
            initialHorizontalAlignment: .left, pageEdgeFillStyle: .system,
            isSurfaceInteractionEnabled: true, isZoomInteractionEnabled: true, allowsUnzoomedSurfacePan: true,
            surfaceInteraction: surface, onLongPress: {})
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let recognizers = allRecognizers(host.view)
        let longPress = try #require(recognizers.compactMap { $0 as? UILongPressGestureRecognizer }
            .first { $0.delegate is MangaSurfaceGestureInput })
        let input = try #require(longPress.delegate as? MangaSurfaceGestureInput)
        #expect(longPress.minimumPressDuration == 0.45)
        #expect(longPress.allowableMovement == 10)
        #expect(abs(input.menuFrame.midX - 200) < 0.5)
        #expect(abs(input.menuFrame.width - 400 / 3) < 0.5)
    }

    private func allRecognizers(_ view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap(allRecognizers)
    }

    private final class OriginalDelegate: NSObject, UIGestureRecognizerDelegate {
        var calls = 0
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            calls += 1
            return true
        }
    }
}
#endif

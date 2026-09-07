#if os(iOS)
import SwiftUI
import UIKit
import Testing
import YamiboXCore
@testable import YamiboXUI

@MainActor @Suite("Paged interaction UIKit integration", .serialized)
struct MangaInteractionUIKitTests {
    @Test(arguments: [false, true], [false, true])
    func mountedBackendsRouteExternalBoundaryExactlyOnce(curl: Bool, canNavigate: Bool) async throws {
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
        try await waitUntil { bridge.route != nil }
        #expect(bridge.route != nil)
        bridge.requestPageTurn(1)
        try await waitUntil { boundaries.count + rejections.count >= 1 }
        bridge.requestPageTurn(-1)
        try await waitUntil { boundaries.count + rejections.count >= 2 }
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
        // SwiftUI supplies converted samples; an idle UIKit pan has no touch translation.
        input.localTranslation = { CGPoint(x: -2, y: 0) }
        input.localVelocity = { .zero }
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == true)
        input.localTranslation = { CGPoint(x: 2, y: 0) }
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == false)
        input.localVelocity = { CGPoint(x: -100, y: 0) }
        #expect(pan.delegate?.gestureRecognizerShouldBegin?(pan) == true)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: pinch) == true)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: UIPinchGestureRecognizer()) == false)
        #expect(pan.delegate?.gestureRecognizer?(pan, shouldRecognizeSimultaneouslyWith: UILongPressGestureRecognizer()) == false)
        runtime.configure(MangaInteractionConfiguration(chromeVisible: true), geometry: runtime.geometry, imageLoaded: true)
        input.update(pan)
        #expect(!pan.isEnabled)
    }

    @Test func longPressRecognizerUsesMenuPolicyAndConfiguredThresholds() throws {
        let runtime = MangaSurfaceRuntime()
        runtime.configure(MangaInteractionConfiguration(),
            geometry: .spread(viewport: CGSize(width: 400, height: 800)), imageLoaded: true)
        let input = MangaSurfaceGestureInput(runtime: runtime, registry: MangaSurfaceGestureRegistry(), role: .longPress)
        let longPress = try #require(input.makeRecognizer() as? UILongPressGestureRecognizer)
        #expect(longPress.delegate === input)
        #expect(longPress.minimumPressDuration == 0.45)
        #expect(longPress.allowableMovement == 10)
        input.menuFrame = CGRect(x: CGFloat(400) / 3, y: 0, width: CGFloat(400) / 3, height: 800)
        input.update(longPress)
        #expect(longPress.isEnabled)
        input.localLocation = { CGPoint(x: 200, y: 400) }
        #expect(longPress.delegate?.gestureRecognizerShouldBegin?(longPress) == true)
        #expect(runtime.menuFrame == input.menuFrame)
        input.localLocation = { CGPoint(x: 100, y: 400) }
        #expect(longPress.delegate?.gestureRecognizerShouldBegin?(longPress) == false)
        input.menuFrame = .zero
        input.update(longPress)
        #expect(!longPress.isEnabled)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            // Yield the main actor so deferred view-update callbacks can actually run.
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
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

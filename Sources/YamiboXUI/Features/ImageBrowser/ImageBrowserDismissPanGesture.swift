#if os(iOS)
import SwiftUI
import UIKit

struct ImageBrowserDismissPanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let zoomFactor: CGFloat
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint, CGPoint) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> ImageBrowserDismissPanInput {
        ImageBrowserDismissPanInput()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = context.coordinator.makeRecognizer()
        updateUIGestureRecognizer(pan, context: context)
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        let input = context.coordinator
        let converter = context.converter
        input.localTranslation = { converter.localTranslation }
        input.localVelocity = { converter.localVelocity }
        input.onChanged = onChanged
        input.onEnded = onEnded
        input.onCancelled = onCancelled
        input.update(pan, isEnabled: isEnabled, zoomFactor: zoomFactor)
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.handle(state: pan.state,
            translation: context.converter.localTranslation ?? pan.translation(in: pan.view),
            velocity: context.converter.localVelocity ?? pan.velocity(in: pan.view))
    }
}

@MainActor
final class ImageBrowserDismissPanInput: NSObject, UIGestureRecognizerDelegate {
    var localTranslation: () -> CGPoint? = { nil }
    var localVelocity: () -> CGPoint? = { nil }
    var onChanged: (CGPoint) -> Void = { _ in }
    var onEnded: (CGPoint, CGPoint) -> Void = { _, _ in }
    var onCancelled: () -> Void = {}

    private var isEnabled = true
    private var zoomFactor: CGFloat = 1
    private var engagementOrigin: CGPoint?
    private let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()

    func makeRecognizer() -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }

    func update(_ pan: UIPanGestureRecognizer, isEnabled: Bool, zoomFactor: CGFloat) {
        self.isEnabled = isEnabled && !ImageBrowserZoomMath.isEngagedZoom(factor: zoomFactor)
        self.zoomFactor = zoomFactor
        callbackScheduler.performViewUpdate {
            if !self.isEnabled { cancel() }
            if pan.isEnabled != self.isEnabled { pan.isEnabled = self.isEnabled }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = localVelocity() ?? pan.velocity(in: pan.view)
        let intent = velocity == .zero ? (localTranslation() ?? pan.translation(in: pan.view)) : velocity
        // Reject sideways/upward drags before recognition; ignoring their updates
        // after recognition would still prevent the ancestor pager from scrolling.
        return ImageBrowserSwipeDismissGesture.canBegin(
            translation: intent, zoomScale: zoomFactor, minimumZoomScale: 1
        )
    }

    func handle(state: UIGestureRecognizer.State, translation: CGPoint, velocity: CGPoint) {
        guard isEnabled else { cancel(); return }
        switch state {
        case .began:
            engagementOrigin = translation
            onChanged(.zero)
        case .changed, .ended:
            guard let origin = engagementOrigin else { return }
            let offset = CGPoint(x: translation.x - origin.x, y: max(translation.y - origin.y, 0))
            if state == .ended {
                engagementOrigin = nil
                onEnded(offset, velocity)
            } else {
                onChanged(offset)
            }
        case .cancelled, .failed:
            cancel()
        default:
            break
        }
    }

    private func cancel() {
        guard engagementOrigin != nil else { return }
        engagementOrigin = nil
        callbackScheduler.publish(onCancelled)
    }
}
#endif

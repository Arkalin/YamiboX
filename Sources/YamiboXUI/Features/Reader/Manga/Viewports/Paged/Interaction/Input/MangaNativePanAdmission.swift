#if os(iOS)
import UIKit

/// Scoped interception for the curl backend. Collection view keeps its own delegate.
@MainActor
final class MangaNativePanAdmission: NSObject, UIGestureRecognizerDelegate {
    private weak var recognizer: UIPanGestureRecognizer?
    private let original: (any UIGestureRecognizerDelegate)?
    var permits: (UIPanGestureRecognizer) -> Bool

    init(_ recognizer: UIPanGestureRecognizer, permits: @escaping (UIPanGestureRecognizer) -> Bool) {
        self.recognizer = recognizer
        original = recognizer.delegate
        self.permits = permits
        super.init()
        recognizer.delegate = self
    }

    func detach() {
        if recognizer?.delegate === self { recognizer?.delegate = original }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, permits(pan) else { return false }
        return original?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldReceive: press) ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldReceive: event) ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if other.delegate is MangaSurfaceGestureInput { return false }
        return original?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: other) ?? false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: other) ?? false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: other) ?? false
    }
}
#endif

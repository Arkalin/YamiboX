#if os(iOS)
import UIKit

/// Owns recognizers, not reading rules or a paging coordinator.
@MainActor
final class MangaNavigationInput: NSObject, UIGestureRecognizerDelegate {
    enum Role { case tap, doubleTap, navigationPan, surfacePan, surfacePinch }
    let tap = UITapGestureRecognizer()
    let doubleTap = UITapGestureRecognizer()
    let navigationPan = UIPanGestureRecognizer()
    let surfacePan = UIPanGestureRecognizer()
    let surfacePinch = UIPinchGestureRecognizer()
    var onEvent: (Role, UIGestureRecognizer) -> Void = { _, _ in }
    var permits: (UIGestureRecognizer) -> Bool = { _ in false }
    var receives: (UIGestureRecognizer, UITouch) -> Bool = { _, _ in true }
    var generation: () -> UInt64 = { 0 }
    private var navigationGeneration: UInt64?

    override init() {
        super.init()
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        for recognizer in recognizers {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.addTarget(self, action: #selector(receive(_:)))
        }
    }

    func install(_ recognizer: UIGestureRecognizer, in view: UIView) {
        guard recognizers.contains(where: { $0 === recognizer }), recognizer.view !== view else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
        view.addGestureRecognizer(recognizer)
    }

    func detach() { recognizers.forEach { $0.view?.removeGestureRecognizer($0) } }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { permits(gestureRecognizer) }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return receives(recognizer, touch)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (recognizer === surfacePan && other === surfacePinch) ||
            (recognizer === surfacePinch && other === surfacePan)
    }

    private var recognizers: [UIGestureRecognizer] { [tap, doubleTap, navigationPan, surfacePan, surfacePinch] }

    @objc private func receive(_ recognizer: UIGestureRecognizer) {
        let role: Role
        if recognizer === tap { role = .tap }
        else if recognizer === doubleTap { role = .doubleTap }
        else if recognizer === navigationPan { role = .navigationPan }
        else if recognizer === surfacePan { role = .surfacePan }
        else if recognizer === surfacePinch { role = .surfacePinch }
        else { return }
        if role == .navigationPan {
            if recognizer.state == .began { navigationGeneration = generation() }
            if recognizer.state == .ended, navigationGeneration != generation() { return }
        }
        onEvent(role, recognizer)
    }
}
#endif

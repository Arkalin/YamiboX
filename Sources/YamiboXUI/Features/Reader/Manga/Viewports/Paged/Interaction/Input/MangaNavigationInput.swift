#if os(iOS)
import UIKit

/// Owns recognizers, not reading rules or a paging coordinator.
@MainActor
final class MangaNavigationInput: NSObject, UIGestureRecognizerDelegate {
    enum Role { case tap, doubleTap, navigationPan }
    let tap = UITapGestureRecognizer()
    let doubleTap = UITapGestureRecognizer()
    let navigationPan: UIPanGestureRecognizer
    var onEvent: (Role, UIGestureRecognizer) -> Void = { _, _ in }
    var permits: (UIGestureRecognizer) -> Bool = { _ in false }
    var receives: (UIGestureRecognizer, UITouch) -> Bool = { _, _ in true }
    var navigationContext: () -> MangaNavigationSession.Context? = { nil }
    private var navigationSession = MangaNavigationSession()

    init(navigationPan: UIPanGestureRecognizer = UIPanGestureRecognizer()) {
        self.navigationPan = navigationPan
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

    func detach() {
        navigationSession.cancel()
        recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { permits(gestureRecognizer) }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            if let scroll = current as? NativeZoomScrollView {
                if recognizer === tap, !scroll.acceptsDiscreteTouch { return false }
                if recognizer === doubleTap, scroll.snapshot.isInteracting { return false }
            }
            view = current.superview
        }
        return receives(recognizer, touch)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard recognizer === tap || recognizer === doubleTap,
              let root = recognizer.view, let scroll = other.view as? NativeZoomScrollView,
              scroll.isDescendant(of: root) else { return false }
        return other === scroll.panGestureRecognizer || other === scroll.pinchGestureRecognizer
    }

    private var recognizers: [UIGestureRecognizer] { [tap, doubleTap, navigationPan] }

    @objc private func receive(_ recognizer: UIGestureRecognizer) {
        let role: Role
        if recognizer === tap { role = .tap }
        else if recognizer === doubleTap { role = .doubleTap }
        else if recognizer === navigationPan { role = .navigationPan }
        else { return }
        if role == .navigationPan {
            switch recognizer.state {
            case .began: navigationSession.begin(in: navigationContext())
            case .ended:
                guard navigationSession.finish(in: navigationContext()) else { return }
            case .cancelled, .failed: navigationSession.cancel()
            default: break
            }
        }
        onEvent(role, recognizer)
    }
}
#endif

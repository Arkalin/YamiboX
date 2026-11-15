import SwiftUI
import UIKit
import YamiboXCore

@MainActor
struct ReaderRemoteActions {
    var tap: ((CGPoint) -> Void)?
    var doubleTap: ((CGPoint) -> Void)?
    var gestureID: AnyHashable?
    var isAvailable: () -> Bool = { true }
    var blocksTap = false
    var hold: ((CGPoint) -> (handled: Bool, drag: ReaderRemoteDrag?))?
    var drag: ((CGPoint) -> ReaderRemoteDrag?)?
    var textHit: ((CGPoint) -> Bool)?
    var transform: ((CGPoint, Bool) -> ReaderRemoteTransform?)?
    var mangaIsZoomed: (() -> Bool)?
    var verticalScroll: (() -> ReaderRemoteScrollTarget?)?
}

extension EnvironmentValues {
    @Entry var readerRemoteInput: ReaderExternalInput? = nil
}

@MainActor
final class ReaderRemoteTargetRegistry {
    private let targets = NSHashTable<ReaderRemoteTargetProbe>.weakObjects()
    weak var window: UIWindow?

    func reset() {
        targets.removeAllObjects()
        window = nil
    }

    func add(_ target: ReaderRemoteTargetProbe) { targets.add(target) }

    func eligible(_ target: ReaderRemoteTargetProbe, at point: CGPoint? = nil) -> Bool {
        guard target.window === window, target.actions.isAvailable(), let frame = target.visibleFrame else { return false }
        return point.map(frame.contains) ?? true
    }

    func contentTarget(where supports: (ReaderRemoteActions) -> Bool) -> ReaderRemoteTargetProbe? {
        targets.allObjects.first { eligible($0) && supports($0.actions) }
    }

    func target(at point: CGPoint, where supports: (ReaderRemoteActions) -> Bool) -> ReaderRemoteTargetProbe? {
        targets.allObjects.filter {
            supports($0.actions) && eligible($0, at: point)
        }.max { first, second in
            if first.priority != second.priority { return first.priority < second.priority }
            return first.bounds.width * first.bounds.height > second.bounds.width * second.bounds.height
        }
    }
}

extension View {
    func readerRemoteActivate(_ action: @escaping () -> Void) -> some View {
        readerRemoteTarget(actions: ReaderRemoteActions(tap: { _ in action() }))
    }

    func readerRemoteTarget(priority: Int = 10, actions: ReaderRemoteActions) -> some View {
        modifier(ReaderRemoteTargetModifier(priority: priority, actions: actions))
    }

}

private struct ReaderRemoteTargetModifier: ViewModifier {
    @Environment(\.readerRemoteInput) private var input
    @Environment(\.isEnabled) private var enabled
    let priority: Int
    let actions: ReaderRemoteActions

    func body(content: Content) -> some View {
        content.background {
            if let input {
                ReaderRemoteTargetAttachment(registry: input.targets, priority: priority, actions: enabled ? actions :
                        .init(gestureID: actions.gestureID, blocksTap: true))
            }
        }
    }
}

private struct ReaderRemoteTargetAttachment: UIViewRepresentable {
    let registry: ReaderRemoteTargetRegistry
    let priority: Int
    let actions: ReaderRemoteActions

    func makeUIView(context: Context) -> ReaderRemoteTargetProbe { ReaderRemoteTargetProbe() }

    func updateUIView(_ view: ReaderRemoteTargetProbe, context: Context) {
        if view.actions.gestureID != actions.gestureID { view.revision = UUID() }
        view.registry = registry
        view.visible = true
        view.priority = priority
        view.actions = actions
        if view.window != nil { registry.add(view) }
    }

    static func dismantleUIView(_ view: ReaderRemoteTargetProbe, coordinator: Void) {
        view.visible = false
        view.actions = .init()
    }
}

final class ReaderRemoteTargetProbe: UIView {
    weak var registry: ReaderRemoteTargetRegistry?
    var visible = false
    var priority = 0
    var actions = ReaderRemoteActions()
    var revision = UUID()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { registry?.add(self) }
    }

    var visibleFrame: CGRect? {
        guard let window, visible else { return nil }
        return readerVisibleFrame(in: window)
    }
}

extension UIView {
    private var readerIsVisible: Bool { !isHidden && alpha >= 0.98 }

    func readerVisibleFrame(in window: UIWindow, slop: CGFloat = 0) -> CGRect? {
        guard self.window === window, readerIsVisible else { return nil }
        var frame = convert(bounds.insetBy(dx: -slop, dy: -slop), to: window).intersection(window.bounds)
        var view = superview
        while let ancestor = view {
            guard ancestor.readerIsVisible else { return nil }
            if ancestor.clipsToBounds || ancestor is UIScrollView {
                frame = frame.intersection(ancestor.convert(ancestor.bounds, to: window))
            }
            view = ancestor.superview
        }
        return frame.isEmpty ? nil : frame
    }

    func readerContains(windowPoint: CGPoint, in window: UIWindow, slop: CGFloat = 0) -> Bool {
        readerVisibleFrame(in: window, slop: slop)?.contains(windowPoint) == true
    }

    func readerHit<T: UIView, Result>(_ type: T.Type, at point: CGPoint, in window: UIWindow,
                                      resolve: (T, CGPoint) -> Result?) -> Result? {
        guard readerIsVisible else { return nil }
        let local = convert(point, from: window)
        if (clipsToBounds || self is UIScrollView), !bounds.contains(local) { return nil }
        for child in subviews.reversed() {
            if let hit = child.readerHit(type, at: point, in: window, resolve: resolve) { return hit }
        }
        guard let match = self as? T, match.point(inside: local, with: nil),
              match.readerContains(windowPoint: point, in: window) else { return nil }
        return resolve(match, local)
    }
}

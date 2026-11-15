import SwiftUI
import UIKit

@MainActor
struct ReaderRemoteActions {
    var tap: ((CGPoint) -> Void)?
    var scroll: ((CGPoint) -> Void)?
    var pinch: ((CGFloat, CGPoint) -> Void)?
    var finishScroll: (() -> Void)?
    var gestureID: AnyHashable?
    var blocksTap = false
    var hold: ((CGPoint) -> Void)?
    var didBeginScroll: (() -> Void)?
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

    func eligible(_ target: ReaderRemoteTargetProbe) -> Bool {
        target.window != nil && target.window === window && target.visible
    }

    func target(at point: CGPoint, where supports: (ReaderRemoteActions) -> Bool) -> ReaderRemoteTargetProbe? {
        targets.allObjects.filter {
            eligible($0) &&
                supports($0.actions) && $0.visibleFrame?.contains(point) == true
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

    @ViewBuilder
    func readerRemoteActivate(_ action: (() -> Void)?) -> some View {
        if let action { readerRemoteActivate(action) } else { self }
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
        var frame = convert(bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha < 0.98 { return nil }
            if view.clipsToBounds || view is UIScrollView {
                frame = frame.intersection(view.convert(view.bounds, to: window))
            }
            ancestor = view.superview
        }
        return frame.isEmpty ? nil : frame
    }
}

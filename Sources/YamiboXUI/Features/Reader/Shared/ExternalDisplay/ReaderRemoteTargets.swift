import SwiftUI
import UIKit

@MainActor
struct ReaderRemoteActions {
    var tap: ((CGPoint, CGRect) -> Void)?
    // Drag receives total travel from touch-down, not a rounded step per frame.
    var drag: ((CGPoint, CGRect) -> Void)?
    var finishDrag: ((Bool) -> Void)?
    var scroll: ((CGPoint) -> Void)?
    var pinch: ((CGFloat, CGPoint) -> Void)?
    var finishScroll: ((Bool) -> Void)?
    var gestureID: AnyHashable?
    var blocksTap = false
    var hold: ((CGPoint) -> Void)?
    var didBeginScroll: (() -> Void)?
    var didBeginDrag: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var readerRemoteInput: ReaderExternalInput? = nil
    @Entry var readerRemoteLayer: ReaderRemoteLayer = .body
    @Entry var readerRemoteVisible = true
    @Entry var readerRemoteDismiss: ReaderPresentationDismissal? = nil
}

struct ReaderPresentationDismissal: Equatable {
    let id: UUID
    let action: @MainActor () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    @MainActor func callAsFunction() { action() }
}

struct ReaderRemoteLayer: Equatable {
    let depth: Int
    let id: UUID?
    static let body = ReaderRemoteLayer(depth: 0, id: nil)
}

@MainActor
final class ReaderRemoteTargetRegistry {
    private let targets = NSHashTable<ReaderRemoteTargetProbe>.weakObjects()
    private let blockers = NSHashTable<ReaderRemoteLayerProbe>.weakObjects()
    weak var window: UIWindow?

    func reset() {
        targets.removeAllObjects()
        blockers.removeAllObjects()
        window = nil
    }

    func add(_ target: ReaderRemoteTargetProbe) { targets.add(target) }
    func add(_ blocker: ReaderRemoteLayerProbe) { blockers.add(blocker) }

    var activeLayer: ReaderRemoteLayer {
        blockers.allObjects.lazy.filter { $0.window === self.window && $0.window != nil }
            .map(\.remoteLayer).max { $0.depth < $1.depth } ?? .body
    }

    var activeDepth: Int { activeLayer.depth }

    func eligible(_ target: ReaderRemoteTargetProbe) -> Bool {
        target.window != nil && target.window === window && target.visible && target.remoteLayer == activeLayer
    }

    func target(at point: CGPoint, where supports: (ReaderRemoteActions) -> Bool) -> ReaderRemoteTargetProbe? {
        let layer = activeLayer
        return targets.allObjects.filter {
            $0.window != nil && $0.window === window && $0.visible && $0.remoteLayer == layer &&
                supports($0.actions) && $0.visibleFrame?.contains(point) == true
        }.max { first, second in
            if first.priority != second.priority { return first.priority < second.priority }
            return first.bounds.width * first.bounds.height > second.bounds.width * second.bounds.height
        }
    }
}

extension View {
    func readerRemoteActivate(_ action: @escaping () -> Void) -> some View {
        readerRemoteTarget(actions: ReaderRemoteActions(tap: { _, _ in action() }))
    }

    @ViewBuilder
    func readerRemoteActivate(_ action: (() -> Void)?) -> some View {
        if let action { readerRemoteActivate(action) } else { self }
    }

    func readerRemoteTarget(priority: Int = 10, actions: ReaderRemoteActions) -> some View {
        modifier(ReaderRemoteTargetModifier(priority: priority, actions: actions))
    }

    /// Attach inside the scroll content. Only the attached public scroll view
    /// receives contentOffset commands; no synthetic events are forwarded.
    func readerRemoteScrollContent() -> some View {
        modifier(ReaderRemoteScrollModifier())
    }

    func readerRemoteSlider(value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        modifier(ReaderRemoteSliderModifier(value: value, range: range))
    }
}

private struct ReaderRemoteSliderModifier: ViewModifier {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var dragStart: Double?

    func body(content: Content) -> some View {
        content.readerRemoteTarget(actions: .init(tap: { point, frame in
            let fraction = min(max((point.x - frame.minX) / max(frame.width, 1), 0), 1)
            value = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        }, drag: { delta, frame in
            guard let dragStart else { return }
            let next = dragStart + Double(delta.x / max(frame.width, 1)) * (range.upperBound - range.lowerBound)
            value = min(max(next, range.lowerBound), range.upperBound)
        }, finishDrag: { _ in
            dragStart = nil
        }, didBeginDrag: {
            dragStart = value
        }))
    }
}

private struct ReaderRemoteTargetModifier: ViewModifier {
    @Environment(\.readerRemoteInput) private var input
    @Environment(\.readerRemoteLayer) private var layer
    @Environment(\.readerRemoteVisible) private var visible
    @Environment(\.isEnabled) private var enabled
    let priority: Int
    let actions: ReaderRemoteActions

    func body(content: Content) -> some View {
        content.background {
            if let input {
                ReaderRemoteTargetAttachment(registry: input.targets, layer: layer,
                    visible: visible, priority: priority, actions: enabled ? actions :
                        .init(gestureID: actions.gestureID, blocksTap: true))
            }
        }
    }
}

private struct ReaderRemoteScrollModifier: ViewModifier {
    @Environment(\.readerRemoteInput) private var input
    @Environment(\.readerRemoteLayer) private var layer
    @Environment(\.readerRemoteVisible) private var visible
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content.background {
            if let input {
                ReaderRemoteTargetAttachment(registry: input.targets, layer: layer,
                    visible: enabled && visible, priority: 0, followsScrollView: true, actions: ReaderRemoteActions())
            }
        }
    }
}

private struct ReaderRemoteTargetAttachment: UIViewRepresentable {
    let registry: ReaderRemoteTargetRegistry
    let layer: ReaderRemoteLayer
    let visible: Bool
    let priority: Int
    var followsScrollView = false
    let actions: ReaderRemoteActions

    func makeUIView(context: Context) -> ReaderRemoteTargetProbe { ReaderRemoteTargetProbe() }

    func updateUIView(_ view: ReaderRemoteTargetProbe, context: Context) {
        if view.actions.gestureID != actions.gestureID { view.revision = UUID() }
        view.registry = registry
        view.remoteLayer = layer
        view.visible = visible
        view.priority = priority
        view.followsScrollView = followsScrollView
        view.actions = followsScrollView ? .init(scroll: { [weak view] delta in
            guard let scroll = view?.enclosingScrollView else { return }
            let inset = scroll.adjustedContentInset
            let y = min(max(-inset.top, scroll.contentOffset.y - delta.y),
                        max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom))
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
        }) : actions
        if view.window != nil { registry.add(view) }
    }

    static func dismantleUIView(_ view: ReaderRemoteTargetProbe, coordinator: Void) {
        view.visible = false
        view.actions = .init()
    }
}

final class ReaderRemoteTargetProbe: UIView {
    weak var registry: ReaderRemoteTargetRegistry?
    var remoteLayer = ReaderRemoteLayer.body
    var visible = false
    var priority = 0
    var followsScrollView = false
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

    var enclosingScrollView: UIScrollView? {
        var current = superview
        while let view = current {
            if let scroll = view as? UIScrollView { return scroll }
            current = view.superview
        }
        return nil
    }

    var visibleFrame: CGRect? {
        guard let window, visible else { return nil }
        let source: UIView
        if followsScrollView {
            guard let scroll = enclosingScrollView else { return nil }
            source = scroll
        } else { source = self }
        var frame = source.convert(source.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = source
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

struct ReaderRemoteLayerAttachment: UIViewRepresentable {
    let registry: ReaderRemoteTargetRegistry
    let layer: ReaderRemoteLayer

    func makeUIView(context: Context) -> ReaderRemoteLayerProbe { ReaderRemoteLayerProbe() }
    func updateUIView(_ view: ReaderRemoteLayerProbe, context: Context) {
        view.registry = registry
        view.remoteLayer = layer
        if view.window != nil { registry.add(view) }
    }
    static func dismantleUIView(_ view: ReaderRemoteLayerProbe, coordinator: Void) { view.remoteLayer = .body }
}

final class ReaderRemoteLayerProbe: UIView {
    weak var registry: ReaderRemoteTargetRegistry?
    var remoteLayer = ReaderRemoteLayer.body

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
}

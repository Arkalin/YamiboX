import SwiftUI
import UIKit
import YamiboXCore

@MainActor
struct ReaderRemoteScrollTarget {
    weak var view: UIScrollView?
    var isAttached: () -> Bool
    var admitsInput: () -> Bool = { true }
    var handle: (ReaderVerticalScrollEvent) -> Bool

    @discardableResult
    func send(_ event: ReaderVerticalScrollEvent) -> Bool { handle(event) }
}

struct ReaderExternalScrollArea: UIViewRepresentable {
    let input: ReaderExternalInput
    let onMenu: () -> Void

    func makeUIView(context: Context) -> ReaderExternalScrollRelay {
        ReaderExternalScrollRelay(input: input)
    }

    func updateUIView(_ view: ReaderExternalScrollRelay, context: Context) {
        view.onMenu = onMenu
        if view.isScrollEnabled != input.isEnabled { view.isScrollEnabled = input.isEnabled }
        view.synchronize()
    }

    static func dismantleUIView(_ view: ReaderExternalScrollRelay, coordinator: ()) {
        view.interrupt()
    }
}

final class ReaderExternalScrollRelay: UIScrollView, UIScrollViewDelegate {
    private struct Run {
        let epoch: UUID
        let target: ReaderRemoteScrollTarget
        var origin: CGFloat
        var lastY: CGFloat
        var limits: ClosedRange<CGFloat>
    }

    private weak var input: ReaderExternalInput?
    private var run: Run?
    private var touch: (epoch: UUID, offsetY: CGFloat)?
    private var synchronizing = false
    private let touchGuard = ReaderScrollTouchGuard()
    var onMenu: (() -> Void)?

    init(input: ReaderExternalInput) {
        self.input = input
        super.init(frame: .zero)
        input.scrollRelay = self
        delegate = self
        alwaysBounceVertical = true
        bouncesHorizontally = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        delaysContentTouches = false
        canCancelContentTouches = true
        isMultipleTouchEnabled = true
        panGestureRecognizer.maximumNumberOfTouches = 1
        touchGuard.onFirstTouch = { [weak self] in self?.recordTouch() }
        touchGuard.onMultipleTouches = { [weak self] in
            guard let self else { return }
            self.touch = nil
            self.interrupt()
            self.panGestureRecognizer.isEnabled = false
            self.panGestureRecognizer.isEnabled = true
        }
        addGestureRecognizer(touchGuard)
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false

        let menu = UIHostingConfiguration {
            ReaderDeviceControlButton.menu { [weak self] in self?.tapMenu() }
                .accessibilityAction { [weak self] in self?.openMenu() }
                .disabled(!input.isEnabled)
        }
        .margins(.all, 0)
        .makeContentView()
        menu.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menu)
        NSLayoutConstraint.activate([
            menu.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor),
            menu.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor),
            menu.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor),
            menu.bottomAnchor.constraint(equalTo: frameLayoutGuide.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        synchronize()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let originalOrigin = bounds.origin
        if bounds.contains(point) { synchronize() }
        return super.hitTest(CGPoint(x: point.x + bounds.minX - originalOrigin.x,
                                     y: point.y + bounds.minY - originalOrigin.y), with: event)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    func synchronize() {
        guard !synchronizing, run == nil, !isTracking, !isDragging, !isDecelerating,
              bounds.height > 0, let view = input?.scrollTarget()?.view, view.bounds.height > 0 else { return }
        synchronizing = true
        defer { synchronizing = false }
        bouncesVertically = view.bouncesVertically
        decelerationRate = view.decelerationRate
        let limits = ReaderVerticalBoundaryAttempt.limits(view)
        let size = CGSize(width: bounds.width, height: bounds.height + limits.upperBound - limits.lowerBound)
        if contentInset != .zero { contentInset = .zero }
        if contentSize != size { contentSize = size }
        let y = min(max(view.contentOffset.y, limits.lowerBound), limits.upperBound)
        let offset = CGPoint(x: 0, y: y - limits.lowerBound)
        if contentOffset != offset { setContentOffset(offset, animated: false) }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        finish(.settled)
        guard !touchGuard.blocked, let input, let touch, input.admits(touch.epoch),
              let target = input.scrollTarget(), let view = target.view else { return }
        if view.isScrollAnimating { view.stopScrollingAndZooming() }
        let y = view.contentOffset.y
        let limits = ReaderVerticalBoundaryAttempt.limits(view)
        let origin = y - touch.offsetY
        run = Run(epoch: input.beginScroll(), target: target, origin: origin, lastY: y, limits: limits)
        setLimits(limits, relativeTo: origin)
        target.send(.began)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !synchronizing, var run else { return }
        guard admits(run), let view = run.target.view else {
            interrupt()
            return
        }
        let limits = ReaderVerticalBoundaryAttempt.limits(view)
        let didRelayout = limits != run.limits
        if didRelayout {
            run.origin += view.contentOffset.y - run.lastY
            run.limits = limits
        }
        let y = run.origin + contentOffset.y
        run.lastY = y
        self.run = run
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
        if isDragging { run.target.send(.dragged(panGestureRecognizer.translation(in: self).y)) }
        if didRelayout { setLimits(limits, relativeTo: run.origin) }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard let run, admits(run),
              panGestureRecognizer.state != .cancelled, panGestureRecognizer.state != .failed else {
            interrupt()
            return
        }
        if run.target.send(.released) {
            finish(.settled)
            stopScrollingAndZooming()
        } else if !decelerate {
            finish(.settled)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finish(.settled) }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard direction == .up || direction == .down,
              input?.step(direction == .down ? .down : .up) == true else { return false }
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }

    var isMoving: Bool { run != nil || isDecelerating || isDragging }

    func interrupt() {
        let wasMoving = isMoving
        finish(.cancelled)
        if wasMoving { stopScrollingAndZooming() }
    }

    private func admits(_ run: Run) -> Bool {
        input?.admits(run.epoch) == true && run.target.isAttached() && run.target.admitsInput()
    }

    private func finish(_ event: ReaderVerticalScrollEvent) {
        guard let run else { return }
        self.run = nil
        guard run.target.isAttached(), let view = run.target.view else { return }
        let range = ReaderVerticalBoundaryAttempt.limits(view)
        let y = min(max(view.contentOffset.y, range.lowerBound), range.upperBound)
        if y != view.contentOffset.y {
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
        }
        run.target.send(event)
    }

    private func setLimits(_ limits: ClosedRange<CGFloat>, relativeTo origin: CGFloat) {
        let inset = UIEdgeInsets(top: origin - limits.lowerBound, left: 0,
                                 bottom: limits.upperBound - origin - (contentSize.height - bounds.height), right: 0)
        guard contentInset != inset else { return }
        synchronizing = true
        contentInset = inset
        synchronizing = false
    }

    private func recordTouch() {
        touch = input.map { ($0.epoch, contentOffset.y) }
    }

    private func tapMenu() {
        guard !touchGuard.blocked, let touch, input?.admits(touch.epoch) == true else { return }
        self.touch = nil
        openMenu()
    }

    private func openMenu() {
        guard window != nil, input?.isEnabled == true else { return }
        onMenu?()
    }
}

private final class ReaderScrollTouchGuard: UIGestureRecognizer {
    var onFirstTouch: (() -> Void)?
    var onMultipleTouches: (() -> Void)?
    private(set) var blocked = false
    private var fingers: Set<UITouch> = []

    init() {
        super.init(target: nil, action: nil)
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if fingers.isEmpty { onFirstTouch?() }
        fingers.formUnion(touches)
        guard !blocked, fingers.count > 1 else { return }
        blocked = true
        onMultipleTouches?()
        state = .began
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        fingers.subtract(touches)
        if fingers.isEmpty { state = blocked ? .ended : .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = blocked ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        fingers.removeAll()
        blocked = false
    }
}

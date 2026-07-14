import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

/// Result of a controller "scroll one viewport" request against the vertical
/// scroll view.
enum NovelReaderControlScrollOutcome {
    case scrolled
    /// Already clamped at the requested edge when pressed; the caller
    /// crosses to the adjacent web page instead.
    case atEdge
    case unavailable
}

final class NovelReaderVerticalScrollCoordinator: NSObject, UIGestureRecognizerDelegate {
    static let boundaryTriggerDistance: CGFloat = 72

    var onBoundaryPullRelease: ((NovelReaderVerticalBoundaryDirection) -> Void)?
    var onViewportMetricsChange: (() -> Void)?
    var onBoundaryPullStateChange: ((NovelReaderVerticalBoundaryPullState) -> Void)?

    private weak var scrollView: UIScrollView?
    private weak var interruptionTapRecognizer: UITapGestureRecognizer?
    private weak var boundaryPanGestureRecognizer: UIPanGestureRecognizer?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var currentViewportMetrics = NovelReaderVerticalViewportMetrics()
    private var pendingViewportMetrics: NovelReaderVerticalViewportMetrics?
    private var isViewportMetricsPublicationScheduled = false
    private var currentBoundaryPullState = NovelReaderVerticalBoundaryPullState.idle
    private var pendingBoundaryPullState: NovelReaderVerticalBoundaryPullState?
    private var isBoundaryPullStatePublicationScheduled = false
    private var isViewportSyncScheduled = false
    private var suppressChromeToggleUntil = CACurrentMediaTime()
    private var lastMotionTime = CACurrentMediaTime()
    private var isRestoringOffset = false
    private let motionSuppressionInterval: CFTimeInterval = 0.35
    private var pendingControlScrollTarget: (y: CGFloat, timestamp: CFTimeInterval)?
    /// Grace window in which a still-animating step's target keeps serving as
    /// the base for the next one, so rapid presses compound predictably.
    private static let controlScrollAnimationGrace: CFTimeInterval = 0.45

    func attach(scrollView: UIScrollView?) {
        guard self.scrollView !== scrollView else { return }
        detachTapRecognizer()
        detachBoundaryPanTarget()
        contentOffsetObservation = nil
        boundsObservation = nil
        self.scrollView = scrollView
        scrollView?.alwaysBounceVertical = true
        installTapRecognizerIfNeeded()
        installBoundaryPanTargetIfNeeded()
        installContentOffsetObservationIfNeeded()
        installBoundsObservationIfNeeded()
        scheduleViewportSync()
    }

    var referenceLineY: CGFloat {
        let height = max(currentViewportMetrics.viewportHeight, 0)
        guard height > 0 else { return 96 }
        return min(max(height * 0.22, 72), 160)
    }

    var hasAttachedScrollView: Bool {
        scrollView != nil
    }

    func interruptScrollingIfNeeded() -> Bool {
        guard let scrollView, scrollView.isDragging || scrollView.isDecelerating else {
            return false
        }

        pendingControlScrollTarget = nil
        let offset = scrollView.contentOffset
        scrollView.setContentOffset(offset, animated: false)
        lastMotionTime = CACurrentMediaTime()

        // Toggling scrollability reliably stops residual momentum from SwiftUI's backing scroll view.
        if scrollView.isDecelerating {
            scrollView.isScrollEnabled = false
            scrollView.isScrollEnabled = true
            scrollView.setContentOffset(offset, animated: false)
        }

        return true
    }

    func restoreOffset(to surfaceFrame: CGRect, intraSurfaceProgress: Double) -> Bool {
        guard let scrollView else { return false }

        let referenceLineY = referenceLineY
        let desiredY = scrollView.contentOffset.y
            + surfaceFrame.minY
            + (surfaceFrame.height * min(max(intraSurfaceProgress, 0), 1))
            - referenceLineY
        let minOffsetY = -scrollView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let targetOffsetY = min(max(desiredY, minOffsetY), maxOffsetY)
        isRestoringOffset = true
        pendingControlScrollTarget = nil
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY), animated: false)
        isRestoringOffset = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1))
            self?.scheduleViewportSync()
        }

        return true
    }

    /// Scrolls one controller step (85% of the viewport) with animation,
    /// clamping at the content edges. Returns `.atEdge` without moving when
    /// the press lands while already clamped, so the caller can cross pages.
    func performControlScrollStep(_ direction: ReaderControlScrollDirection) -> NovelReaderControlScrollOutcome {
        guard let scrollView, scrollView.bounds.height > 0 else { return .unavailable }

        let minOffsetY = -scrollView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let currentY = scrollView.contentOffset.y
        let edgeTolerance: CGFloat = 0.5
        let isAtEdge = switch direction {
        case .down: currentY >= maxOffsetY - edgeTolerance
        case .up: currentY <= minOffsetY + edgeTolerance
        }
        if isAtEdge {
            return .atEdge
        }

        let now = CACurrentMediaTime()
        var baseY = currentY
        if let pending = pendingControlScrollTarget,
           now - pending.timestamp < Self.controlScrollAnimationGrace {
            baseY = pending.y
        }
        let step = scrollView.bounds.height * CGFloat(ReaderControlCommandResolver.verticalScrollViewportFraction)
        let desiredTargetY = direction == .down ? baseY + step : baseY - step
        let targetY = min(max(desiredTargetY, minOffsetY), maxOffsetY)
        pendingControlScrollTarget = (targetY, now)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: true)
        return .scrolled
    }

    func shouldSuppressChromeToggle() -> Bool {
        let now = CACurrentMediaTime()
        if now - lastMotionTime <= motionSuppressionInterval {
            suppressChromeToggleUntil = now
            return true
        }
        guard now <= suppressChromeToggleUntil else { return false }
        suppressChromeToggleUntil = now
        return true
    }

    private func installTapRecognizerIfNeeded() {
        guard let scrollView, interruptionTapRecognizer == nil else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleInterruptionTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        scrollView.addGestureRecognizer(recognizer)
        interruptionTapRecognizer = recognizer
    }

    private func installContentOffsetObservationIfNeeded() {
        guard let scrollView else { return }
        contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
            guard let oldValue = change.oldValue, let newValue = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard oldValue != newValue else { return }
                guard !self.isRestoringOffset else { return }
                self.lastMotionTime = CACurrentMediaTime()
                self.scheduleViewportSync()
            }
        }
    }

    private func installBoundsObservationIfNeeded() {
        guard let scrollView else { return }
        boundsObservation = scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleViewportSync()
            }
        }
    }

    private func scheduleViewportSync() {
        guard !isViewportSyncScheduled else { return }
        isViewportSyncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
            guard let self else { return }
            self.isViewportSyncScheduled = false
            self.syncViewportMetrics()
        }
    }

    private func syncViewportMetrics() {
        let metrics: NovelReaderVerticalViewportMetrics
        guard let scrollView else {
            metrics = NovelReaderVerticalViewportMetrics()
            updateViewportMetrics(metrics)
            updateBoundaryPullState(.idle)
            return
        }
        let contentOffsetY = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        metrics = NovelReaderVerticalViewportMetrics(
            contentOffsetY: contentOffsetY,
            viewportHeight: scrollView.bounds.height
        )
        updateViewportMetrics(metrics)
        updateBoundaryPullState(boundaryPullState(for: scrollView))
    }

    private func updateViewportMetrics(_ metrics: NovelReaderVerticalViewportMetrics) {
        guard metrics != currentViewportMetrics else { return }
        currentViewportMetrics = metrics
        pendingViewportMetrics = metrics
        scheduleViewportMetricsPublication()
    }

    private func scheduleViewportMetricsPublication() {
        guard !isViewportMetricsPublicationScheduled else { return }
        isViewportMetricsPublicationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
            guard let self else { return }
            self.isViewportMetricsPublicationScheduled = false
            guard let metrics = self.pendingViewportMetrics else { return }
            self.pendingViewportMetrics = nil
            guard metrics == self.currentViewportMetrics else { return }
            self.onViewportMetricsChange?()
        }
    }

    private func boundaryPullState(for scrollView: UIScrollView) -> NovelReaderVerticalBoundaryPullState {
        guard let panGestureRecognizer = boundaryPanGestureRecognizer,
              scrollView.isDragging,
              panGestureRecognizer.state == .began || panGestureRecognizer.state == .changed else {
            return .idle
        }

        let minOffsetY = -scrollView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let topOverscroll = max(minOffsetY - scrollView.contentOffset.y, 0)
        let bottomOverscroll = max(scrollView.contentOffset.y - maxOffsetY, 0)
        let translationY = panGestureRecognizer.translation(in: scrollView).y

        if topOverscroll > 0, translationY > 0 {
            return NovelReaderVerticalBoundaryPullState(
                direction: .previous,
                distance: topOverscroll,
                isArmed: topOverscroll >= Self.boundaryTriggerDistance
            )
        }

        if bottomOverscroll > 0, translationY < 0 {
            return NovelReaderVerticalBoundaryPullState(
                direction: .next,
                distance: bottomOverscroll,
                isArmed: bottomOverscroll >= Self.boundaryTriggerDistance
            )
        }

        return .idle
    }

    private func updateBoundaryPullState(_ state: NovelReaderVerticalBoundaryPullState) {
        if state == currentBoundaryPullState {
            pendingBoundaryPullState = nil
            return
        }
        guard state != pendingBoundaryPullState else {
            return
        }
        pendingBoundaryPullState = state
        scheduleBoundaryPullStatePublication()
    }

    private func scheduleBoundaryPullStatePublication() {
        guard !isBoundaryPullStatePublicationScheduled else { return }
        isBoundaryPullStatePublicationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
            guard let self else { return }
            self.isBoundaryPullStatePublicationScheduled = false
            guard let state = self.pendingBoundaryPullState else { return }
            self.pendingBoundaryPullState = nil
            if state != self.currentBoundaryPullState {
                self.currentBoundaryPullState = state
                self.onBoundaryPullStateChange?(state)
            }
        }
    }

    private func detachTapRecognizer() {
        if let recognizer = interruptionTapRecognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        interruptionTapRecognizer = nil
    }

    private func installBoundaryPanTargetIfNeeded() {
        guard let panGestureRecognizer = scrollView?.panGestureRecognizer,
              boundaryPanGestureRecognizer !== panGestureRecognizer else {
            return
        }
        panGestureRecognizer.addTarget(self, action: #selector(handleBoundaryPan(_:)))
        boundaryPanGestureRecognizer = panGestureRecognizer
    }

    private func detachBoundaryPanTarget() {
        if let recognizer = boundaryPanGestureRecognizer {
            recognizer.removeTarget(self, action: #selector(handleBoundaryPan(_:)))
        }
        boundaryPanGestureRecognizer = nil
        updateBoundaryPullState(.idle)
    }

    @objc
    private func handleInterruptionTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        guard interruptScrollingIfNeeded() else { return }
        suppressChromeToggleUntil = CACurrentMediaTime() + motionSuppressionInterval
    }

    @objc
    private func handleBoundaryPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .ended, .cancelled, .failed:
            let releasedState = currentBoundaryPullState
            updateBoundaryPullState(.idle)
            guard releasedState.isArmed,
                  let direction = releasedState.direction else {
                return
            }
            onBoundaryPullRelease?(direction)
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating
    }
}

struct NovelReaderScrollViewResolver: UIViewRepresentable {
    let onResolve: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> NovelReaderScrollViewResolverView {
        let view = NovelReaderScrollViewResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: NovelReaderScrollViewResolverView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveScrollViewIfNeeded()
    }
}

final class NovelReaderScrollViewResolverView: UIView {
    var onResolve: ((UIScrollView?) -> Void)?
    private weak var resolvedScrollView: UIScrollView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolveScrollViewIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveScrollViewIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolveScrollViewIfNeeded()
    }

    func resolveScrollViewIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.nearestAncestorScrollView() else { return }
            guard scrollView !== self.resolvedScrollView else { return }
            self.resolvedScrollView = scrollView
            self.onResolve?(scrollView)
        }
    }

    private func nearestAncestorScrollView() -> UIScrollView? {
        var candidate = superview
        while let current = candidate {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            if let scrollView = current.firstDescendantScrollView(excluding: self) {
                return scrollView
            }
            candidate = current.superview
        }
        return nil
    }
}

private extension UIView {
    func firstDescendantScrollView(excluding excludedView: UIView) -> UIScrollView? {
        for subview in subviews where subview !== excludedView {
            if let scrollView = subview as? UIScrollView {
                return scrollView
            }
            if let scrollView = subview.firstDescendantScrollView(excluding: excludedView) {
                return scrollView
            }
        }
        return nil
    }
}
#endif

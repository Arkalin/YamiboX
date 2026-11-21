import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit


final class NovelReaderVerticalScrollCoordinator: NSObject, UIGestureRecognizerDelegate {
    static let boundaryTriggerDistance = ReaderVerticalBoundaryAttempt.triggerDistance

    var onBoundaryPullRelease: ((NovelReaderVerticalBoundaryDirection, @escaping () -> Bool) -> Void)?
    var onDragStart: (() -> Void)?
    var onSettle: (() -> Void)?
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
    private var controlScroll = ReaderVerticalScrollStep()

    func attach(scrollView: UIScrollView?) {
        if scrollView == nil {
            onSettle = nil
            onDragStart = nil
            onBoundaryPullRelease = nil
            onViewportMetricsChange = nil
            onBoundaryPullStateChange = nil
        }
        guard self.scrollView !== scrollView else { return }
        detachTapRecognizer()
        detachBoundaryPanTarget()
        contentOffsetObservation = nil
        boundsObservation = nil
        self.scrollView = scrollView
        controlScroll.reset()
        scrollView?.alwaysBounceVertical = true
        installTapRecognizerIfNeeded()
        installBoundaryPanTargetIfNeeded()
        installContentOffsetObservationIfNeeded()
        installBoundsObservationIfNeeded()
        scheduleViewportSync()
    }

    var referenceLineY: CGFloat {
        guard let bounds = scrollView?.bounds else { return 96 }
        return NovelReaderVerticalPositioning.viewportReadingAnchorLineY(in: bounds)
    }

    var hasAttachedScrollView: Bool {
        scrollView != nil
    }

    var attachedScrollView: UIScrollView? { scrollView }

    func interruptScrollingIfNeeded() -> Bool {
        guard let scrollView, scrollView.isDragging || scrollView.isDecelerating else {
            return false
        }

        controlScroll.reset()
        let offset = scrollView.contentOffset
        scrollView.setContentOffset(offset, animated: false)
        lastMotionTime = CACurrentMediaTime()

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
        controlScroll.reset()
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY), animated: false)
        isRestoringOffset = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1))
            self?.scheduleViewportSync()
        }

        return true
    }

    func performControlScrollStep(_ direction: ReaderControlScrollDirection) -> ReaderVerticalScrollStep.Outcome {
        controlScroll.perform(direction, in: scrollView)
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
        if let pan = boundaryPanGestureRecognizer, scrollView.isDragging,
           pan.state == .began || pan.state == .changed {
            handleScroll(.dragged(pan.translation(in: scrollView).y))
        }
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

    @discardableResult
    func handleScroll(_ event: ReaderVerticalScrollEvent,
                      canNavigate: (NovelReaderVerticalBoundaryDirection) -> Bool = { _ in false },
                      admitsRelease: @escaping () -> Bool = { true }) -> Bool {
        switch event {
        case .began:
            controlScroll.reset()
            updateBoundaryPullState(.idle)
            onDragStart?()
        case let .dragged(translation):
            if let scrollView {
                updateBoundaryPullState(boundaryPullState(y: scrollView.contentOffset.y, translationY: translation))
            }
        case .released:
            let state = pendingBoundaryPullState ?? currentBoundaryPullState
            updateBoundaryPullState(.idle)
            if state.isArmed, let direction = state.direction {
                onBoundaryPullRelease?(direction, admitsRelease)
                return canNavigate(direction)
            }
        case .settled, .cancelled:
            updateBoundaryPullState(.idle)
            onSettle?()
        }
        return false
    }

    private func boundaryPullState(y: CGFloat, translationY: CGFloat) -> NovelReaderVerticalBoundaryPullState {
        guard let scrollView else { return .idle }
        let limits = ReaderVerticalBoundaryAttempt.limits(scrollView)
        let topOverscroll = max(limits.lowerBound - y, 0)
        let bottomOverscroll = max(y - limits.upperBound, 0)
        let boundary = ReaderVerticalBoundaryAttempt.boundary(offsetY: y, minOffsetY: limits.lowerBound,
                                                             maxOffsetY: limits.upperBound, translationY: translationY)

        if topOverscroll > 0, translationY > 0 {
            return NovelReaderVerticalBoundaryPullState(
                direction: .previous,
                distance: topOverscroll,
                isArmed: boundary == .previous
            )
        }

        if bottomOverscroll > 0, translationY < 0 {
            return NovelReaderVerticalBoundaryPullState(
                direction: .next,
                distance: bottomOverscroll,
                isArmed: boundary == .next
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
        case .began: handleScroll(.began)
        case .ended: handleScroll(.released)
        case .cancelled, .failed: updateBoundaryPullState(.idle)
        default: break
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
#endif

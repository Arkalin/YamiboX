#if os(iOS)
import UIKit

struct NativeZoomSnapshot: Equatable {
    var factor: CGFloat
    var visibleRect: CGRect
    var isDragging: Bool
    var isDecelerating: Bool
    var isZooming: Bool
    var isZoomBouncing: Bool

    var isInteracting: Bool { isDragging || isDecelerating || isZooming || isZoomBouncing }
}

/// UIKit owns the transform and offset. Clients supply base geometry and discrete
/// commands, never write a mirrored transform back during a gesture.
class NativeZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let zoomContentView = UIView()
    let callbackScheduler = SwiftUIViewUpdateCallbackScheduler()
    var onSnapshotChange: ((NativeZoomSnapshot) -> Void)?
    var onInteractionEnd: (() -> Void)?
    var onViewportSizeChange: ((CGSize, NativeZoomSnapshot) -> Void)?
    var permitsPan: ((UIPanGestureRecognizer) -> Bool)?
    var permitsPinch: (() -> Bool)?
    var centersVertically = true
    private(set) var baseContentSize: CGSize = .zero
    private(set) var lastViewportSize: CGSize = .zero
    private var isUpdatingGeometry = false
    private var lastSnapshot: NativeZoomSnapshot?
    private var lastMotionTime: CFTimeInterval?
    var currentTime: () -> CFTimeInterval = CACurrentMediaTime

    var normalizedZoomFactor: CGFloat { zoomScale / max(minimumZoomScale, 0.0001) }

    var acceptsDiscreteTouch: Bool {
        !snapshot.isInteracting && (lastMotionTime.map { currentTime() - $0 > 0.35 } ?? true)
    }

    var snapshot: NativeZoomSnapshot {
        NativeZoomSnapshot(
            factor: normalizedZoomFactor,
            visibleRect: convert(bounds, to: zoomContentView),
            isDragging: isDragging, isDecelerating: isDecelerating,
            isZooming: isZooming, isZoomBouncing: isZoomBouncing
        )
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bounces = true
        bouncesZoom = true
        decelerationRate = .normal
        scrollsToTop = false
        backgroundColor = .clear
        zoomContentView.backgroundColor = .clear
        addSubview(zoomContentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configureGeometry(contentSize size: CGSize, minimumScale: CGFloat = 1, maximumFactor: CGFloat) {
        guard size.width > 0, size.height > 0, minimumScale > 0 else { return }
        guard size != baseContentSize || minimumScale != minimumZoomScale
                || maximumZoomScale != minimumScale * maximumFactor else { return }
        callbackScheduler.performViewUpdate {
            let previous = snapshot
            let hadGeometry = baseContentSize != .zero
            isUpdatingGeometry = true
            baseContentSize = size
            minimumZoomScale = minimumScale
            maximumZoomScale = minimumScale * maximumFactor
            zoomContentView.bounds = CGRect(origin: .zero, size: size)
            setZoomScale(minimumScale * min(maximumFactor, max(1, hadGeometry ? previous.factor : 1)), animated: false)
            zoomContentView.center = CGPoint(x: size.width * zoomScale / 2, y: size.height * zoomScale / 2)
            contentSize = CGSize(width: size.width * zoomScale, height: size.height * zoomScale)
            recenterContent()
            if hadGeometry {
                place(contentPoint: CGPoint(x: previous.visibleRect.midX, y: previous.visibleRect.midY),
                      at: CGPoint(x: bounds.width / 2, y: bounds.height / 2))
            }
            isUpdatingGeometry = false
            reportSnapshot()
        }
    }

    func zoom(factor: CGFloat, centeredAt contentPoint: CGPoint, animated: Bool) {
        let scale = min(maximumZoomScale, max(minimumZoomScale, minimumZoomScale * factor))
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: contentPoint.x - size.width / 2, y: contentPoint.y - size.height / 2,
                        width: size.width, height: size.height),
             animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    func resetZoom(animated: Bool) {
        callbackScheduler.performViewUpdate {
            setZoomScale(minimumZoomScale, animated: animated && !UIAccessibility.isReduceMotionEnabled)
        }
    }

    func place(contentPoint: CGPoint, at viewportPoint: CGPoint, animated: Bool = false) {
        setContentOffset(clampedOffset(CGPoint(
            x: contentPoint.x * zoomScale - viewportPoint.x,
            y: contentPoint.y * zoomScale - viewportPoint.y
        )), animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    func clampedOffset(_ offset: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(offset.x, -contentInset.left), max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)),
            y: min(max(offset.y, -contentInset.top), max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom))
        )
    }

    /// Explicit navigation/unmount only. Chrome changes must not call this.
    func stopInteraction() {
        stopScrollingAndZooming()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        callbackScheduler.performViewUpdate {
            if bounds.size != lastViewportSize, bounds.width > 0, bounds.height > 0 {
                let previous = lastSnapshot ?? snapshot
                lastViewportSize = bounds.size
                onViewportSizeChange?(bounds.size, previous)
            }
            recenterContent()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomContentView }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { reportSnapshot() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        recenterContent()
        reportSnapshot()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { reportSnapshot() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { reportSnapshot() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        reportSnapshot()
        if !decelerate { onInteractionEnd?() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportSnapshot()
        onInteractionEnd?()
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        reportSnapshot()
        onInteractionEnd?()
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        reportSnapshot()
        onInteractionEnd?()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard super.gestureRecognizerShouldBegin(gestureRecognizer) else { return false }
        if gestureRecognizer === panGestureRecognizer { return permitsPan?(panGestureRecognizer) ?? true }
        if gestureRecognizer === pinchGestureRecognizer { return permitsPinch?() ?? true }
        return true
    }

    private func recenterContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = centersVertically ? max(0, (bounds.height - contentSize.height) / 2) : 0
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets { contentInset = insets }
    }

    private func reportSnapshot() {
        guard !isUpdatingGeometry else { return }
        let value = snapshot
        if value.isInteracting { lastMotionTime = currentTime() }
        // UIKit can send didScroll after bounds changes but before layout. Keep
        // the last old-viewport anchor until the resize callback has consumed it.
        if bounds.size == lastViewportSize || lastViewportSize == .zero { lastSnapshot = value }
        onSnapshotChange?(value)
    }
}
#endif

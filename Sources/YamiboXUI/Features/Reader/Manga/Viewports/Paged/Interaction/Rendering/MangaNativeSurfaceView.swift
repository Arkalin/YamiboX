#if os(iOS)
import SwiftUI
import UIKit

/// The same host is used for a fitted bitmap, a hosted spread, and page-curl.
final class MangaNativeSurfaceView: NativeZoomScrollView, MangaNativeSurfaceControlling, UIGestureRecognizerDelegate {
    private(set) var runtime: MangaSurfaceRuntime?
    private let instance = UUID()
    private var geometry: MangaSurfaceGeometry = .spread(viewport: .zero)
    private var configuring = false
    private var callbackRevision: UInt64 = 0
    var onLongPress: (() -> Void)?
    var onBaseSizeChange: ((CGSize) -> Void)?
    var onInformationZoomChange: ((Bool) -> Void)?
    private(set) lazy var longPress = UILongPressGestureRecognizer(target: self, action: #selector(showMenu(_:)))

    override init() {
        super.init()
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 10
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        addGestureRecognizer(longPress)
        permitsPan = { [weak self] pan in
            guard let self, let runtime = self.runtime, runtime.permitsInteraction() else { return false }
            if pan.numberOfTouches > 1 || self.isZooming {
                return runtime.canPinch
            }
            let velocity = pan.velocity(in: self)
            let translation = pan.translation(in: self)
            return runtime.decision(.pan(translation: CGSize(width: translation.x, height: translation.y),
                velocity: CGSize(width: velocity.x, height: velocity.y))) == .panImage
        }
        permitsPinch = { [weak self] in
            guard let runtime = self?.runtime else { return false }
            return runtime.canPinch && runtime.permitsInteraction()
        }
        onSnapshotChange = { [weak self] snapshot in
            self?.onInformationZoomChange?(snapshot.factor > 1.001 || snapshot.isInteracting)
            self?.publishNativeState()
        }
        onViewportSizeChange = { [weak self] size, previous in
            guard let self else { return }
            self.updateGeometry(self.geometry.replacingNativeViewport(size), preserving: previous)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(runtime: MangaSurfaceRuntime, configuration: MangaInteractionConfiguration,
                   geometry: MangaSurfaceGeometry, imageLoaded: Bool) {
        callbackScheduler.performViewUpdate {
            if self.runtime !== runtime {
                detach()
                self.runtime = runtime
                runtime.attachNative(self, instance: instance)
            }
            guard runtime.isMounted(instance) else { return }
            let contentChanged = self.geometry.replacingNativeViewport(geometry.viewport) != geometry
            let needsContentGeometry = contentChanged || baseContentSize == .zero
            let next = needsContentGeometry ? geometry.replacingNativeViewport(bounds.size) : self.geometry
            runtime.configure(configuration, geometry: next, imageLoaded: imageLoaded)
            // Viewport-only changes belong to layoutSubviews, which has the last
            // old-bounds snapshot. A representable update may arrive on either side.
            if needsContentGeometry {
                updateGeometry(next, preserving: baseContentSize == .zero ? nil : snapshot)
            }
            let maximum: CGFloat = configuration.zoomEnabled ? 4 : 1
            if maximumZoomScale != maximum { maximumZoomScale = maximum }
            publishNativeState()
        }
    }

    func detach() {
        callbackRevision &+= 1
        runtime?.unmount(instance)
        runtime = nil
    }

    private func updateGeometry(_ next: MangaSurfaceGeometry, preserving previous: NativeZoomSnapshot?) {
        guard runtime?.isMounted(instance) == true else { return }
        guard next.viewport.width > 0, next.viewport.height > 0 else { geometry = next; return }
        let oldSize = baseContentSize
        let changedContent = geometry.replacingNativeViewport(next.viewport) != next
        geometry = next
        let size = next.nativeBaseSize
        guard size.width > 0, size.height > 0 else { return }
        configuring = true
        runtime?.configure(runtime!.configuration, geometry: next, imageLoaded: runtime!.imageLoaded)
        configureGeometry(contentSize: size, maximumFactor: runtime?.configuration.zoomEnabled == false ? 1 : 4)
        onBaseSizeChange?(size)
        if let previous, previous.visibleRect.width > 0, previous.visibleRect.height > 0,
           !changedContent, oldSize.width > 0, oldSize.height > 0 {
            place(contentPoint: CGPoint(x: previous.visibleRect.midX * size.width / oldSize.width,
                                        y: previous.visibleRect.midY * size.height / oldSize.height),
                  at: CGPoint(x: bounds.width / 2, y: bounds.height / 2))
        } else {
            resetZoom(animated: false)
            placeAtRest()
        }
        configuring = false
        publishNativeState()
    }

    private func placeAtRest() {
        let frame = geometry.nativeImageFrame(MangaSurfaceTransform())
        setContentOffset(clampedOffset(CGPoint(x: -frame.minX, y: -frame.minY)), animated: false)
    }

    func applyNative(_ decision: MangaInteractionDecision, animated: Bool) {
        guard runtime?.isMounted(instance) == true else { return }
        switch decision {
        case let .zoom(point):
            guard runtime?.permitsInteraction() == true else { return }
            if MangaPageZoomPolicy.isZoomedForDoubleTapReset(normalizedZoomFactor) {
                let resting = geometry.nativeImageFrame(MangaSurfaceTransform())
                zoom(factor: 1, centeredAt: CGPoint(x: bounds.width / 2 - resting.minX,
                                                   y: bounds.height / 2 - resting.minY), animated: animated)
            } else {
                let local = CGPoint(x: point.x + bounds.minX, y: point.y + bounds.minY)
                zoom(factor: 2, centeredAt: convert(local, to: zoomContentView), animated: animated)
            }
        case let .reveal(edge):
            let x = edge == .left ? -contentInset.left : max(-contentInset.left, contentSize.width - bounds.width + contentInset.right)
            setContentOffset(CGPoint(x: x, y: contentOffset.y), animated: animated && !UIAccessibility.isReduceMotionEnabled)
        default: break
        }
    }

    func cancelNative(reset: Bool) {
        callbackRevision &+= 1
        callbackScheduler.performViewUpdate {
            stopInteraction()
            if reset {
                resetZoom(animated: false)
                placeAtRest()
            }
            publishNativeState()
        }
    }

    private func publishNativeState() {
        guard !configuring, let runtime, runtime.isMounted(instance), baseContentSize != .zero else { return }
        let value = snapshot
        let frame = convert(zoomContentView.bounds, from: zoomContentView).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let rest = geometry.nativeRestingOffset(scale: value.factor)
        let transform = MangaSurfaceTransform(scale: value.factor, offset: CGSize(
            width: frame.minX - (bounds.width - frame.width) / 2 - rest.width,
            height: frame.minY - (bounds.height - frame.height) / 2 - rest.height
        ))
        let menuFrame = MangaPageLongPressHitTesting.allowedFrame(in: CGRect(origin: .zero, size: bounds.size), imageFrame: frame)
        let revision = callbackRevision
        callbackScheduler.publish { [weak runtime, weak self] in
            guard let self, self.callbackRevision == revision else { return }
            runtime?.receiveNative(transform, interacting: value.isInteracting, instance: self.instance)
            if runtime?.isMounted(self.instance) == true { runtime?.setMenuFrame(menuFrame) }
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === longPress {
            guard onLongPress != nil else { return false }
            let point = longPress.location(in: self)
            let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
            return runtime?.decision(.longPress(local)) == .menu
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view?.isDescendant(ofType: UIControl.self) != true
    }

    @objc private func showMenu(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, runtime?.isMounted(instance) == true else { return }
        onLongPress?()
    }
}

extension MangaSurfaceGeometry {
    func replacingNativeViewport(_ viewport: CGSize) -> Self {
        switch self {
        case let .image(size, _, fit, alignment): .image(size: size, viewport: viewport, fit: fit, alignment: alignment)
        case .spread: .spread(viewport: viewport)
        }
    }

    var nativeBaseSize: CGSize {
        switch self {
        case let .image(size, viewport, fit, alignment):
            MangaPagedImageSurfaceLayout(imageSize: size, containerSize: viewport, fitMode: fit,
                initialHorizontalAlignment: alignment, zoomScale: 1).fittedImageSize
        case let .spread(viewport): viewport
        }
    }

    func nativeRestingOffset(scale: CGFloat) -> CGSize {
        switch self {
        case let .image(size, viewport, fit, alignment):
            MangaPagedImageSurfaceLayout(imageSize: size, containerSize: viewport, fitMode: fit,
                initialHorizontalAlignment: alignment, zoomScale: scale).restingOffset
        case .spread: .zero
        }
    }

    func nativeImageFrame(_ transform: MangaSurfaceTransform) -> CGRect {
        let size = CGSize(width: nativeBaseSize.width * transform.scale, height: nativeBaseSize.height * transform.scale)
        let rest = nativeRestingOffset(scale: transform.scale)
        return CGRect(x: (viewport.width - size.width) / 2 + rest.width + transform.offset.width,
                      y: (viewport.height - size.height) / 2 + rest.height + transform.offset.height,
                      width: size.width, height: size.height)
    }
}
#endif

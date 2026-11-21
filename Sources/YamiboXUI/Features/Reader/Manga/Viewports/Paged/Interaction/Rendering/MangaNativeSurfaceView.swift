#if os(iOS)
import SwiftUI
import UIKit

final class MangaNativeSurfaceView: NativeZoomScrollView, MangaNativeSurfaceControlling, UIGestureRecognizerDelegate {
    enum PageContent {
        case image(String)
        case spread(left: SpreadImage?, right: SpreadImage?)
    }

    struct SpreadImage {
        let pageID: String
        let runtime: MangaSurfaceRuntime?
    }

    private(set) var runtime: MangaSurfaceRuntime?
    private let instance = UUID()
    private var geometry: MangaSurfaceGeometry = .spread(viewport: .zero)
    private var configuring = false
    private var callbackRevision: UInt64 = 0
    var onLongPress: (() -> Void)?
    var onBaseSizeChange: ((CGSize) -> Void)?
    var onInformationZoomChange: ((Bool) -> Void)?
    var pageContent: PageContent?
    var handoff: MangaViewportHandoff?
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
            guard let self else { return }
            if !self.configuring, let state = self.pinchGestureRecognizer?.state,
               snapshot.isZooming, state == .began || state == .changed {
                self.runtime?.finishPageEntry()
            }
            self.onInformationZoomChange?(MangaPageZoomPolicy.isActive(snapshot.factor) || snapshot.isInteracting)
            self.publishNativeState()
            if !self.configuring { self.runtime?.nativeInteractionDidChange(instance: self.instance) }
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
            if needsContentGeometry {
                updateGeometry(next, preserving: baseContentSize == .zero ? nil : snapshot)
            }
            let maximum: CGFloat = configuration.zoomEnabled ? 4 : 1
            if maximumZoomScale != maximum { maximumZoomScale = maximum }
            if !imageLoaded, runtime.pendingPageEntry != nil { showUnzoomedPlaceholder() }
            applyPendingPageEntry()
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
        applyPendingPageEntry()
        publishNativeState()
        notifySpreadOfReadyImage()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { notifySpreadOfReadyImage() }
    }

    var pageFocus: MangaViewportFocus? {
        guard baseContentSize != .zero, normalizedZoomFactor > 1.001, let pageContent else { return nil }
        let rect = snapshot.visibleRect
        let pageID: String
        let frame: CGRect
        switch pageContent {
        case let .image(id):
            pageID = id
            frame = CGRect(origin: .zero, size: baseContentSize)
        case let .spread(left, right):
            let image = rect.midX < baseContentSize.width / 2 ? left ?? right : right ?? left
            guard let image, let bitmap = spreadImageFrame(for: image) else { return nil }
            pageID = image.pageID
            frame = bitmap
        }
        return MangaViewportFocus(pageID: pageID, point: CGPoint(
            x: min(max((rect.midX - frame.minX) / frame.width, 0), 1),
            y: min(max((rect.midY - frame.minY) / frame.height, 0), 1)
        ), factor: normalizedZoomFactor)
    }

    var imageInteractionState: MangaImageInteractionState {
        .init(factor: normalizedZoomFactor, isMoving: hasImageMotion,
              hasTouch: isTracking || panGestureRecognizer.numberOfTouches > 0 ||
                (pinchGestureRecognizer?.numberOfTouches ?? 0) > 0)
    }

    private var hasImageMotion: Bool {
        isZooming || isZoomAnimating || isZoomBouncing || isDragging || isDecelerating ||
            isScrollAnimating || isDrivenTransform ||
            panGestureRecognizer.state == .began || panGestureRecognizer.state == .changed ||
            pinchGestureRecognizer?.state == .began || pinchGestureRecognizer?.state == .changed
    }

    func remoteImageHit(at point: CGPoint, in window: UIWindow) -> Bool {
        onLongPress != nil && runtime?.imageLoaded == true && runtime?.permitsInteraction() == true &&
            readerContains(windowPoint: point, in: window) &&
            zoomContentView.readerContains(windowPoint: point, in: window)
    }

    func doubleTapFromTrackpad(at windowPoint: CGPoint) {
        guard let window, let runtime else { return }
        let point = convert(windowPoint, from: window)
        let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        let decision = runtime.decision(.doubleTap(local))
        guard case .zoom = decision else { return }
        runtime.apply(decision)
    }

    func applyPendingPageEntry() {
        guard !configuring, baseContentSize.width > 0, baseContentSize.height > 0,
              let runtime, runtime.isMounted(instance), runtime.canPinch,
              maximumZoomScale > minimumZoomScale else { return }
        let entry = runtime.pendingPageEntry
        let content = CGRect(origin: .zero, size: baseContentSize)
        var placement: (focus: MangaViewportFocus, frame: CGRect)?
        if runtime.zoomSession?.owns(runtime) == true, let focus = handoff?.focusToRestore {
            switch pageContent {
            case .image(let id) where id == focus.pageID:
                placement = (focus, content)
            case let .spread(left, right):
                if let image = left?.pageID == focus.pageID ? left : (right?.pageID == focus.pageID ? right : nil) {
                    guard let frame = spreadImageFrame(for: image) else {
                        if entry != nil { showUnzoomedPlaceholder() }
                        return
                    }
                    placement = (focus, frame)
                }
            default:
                break
            }
        }
        guard placement != nil || entry != nil else { return }

        var entryFrame = content
        if placement == nil, let entry, entry.factor > 1, case let .spread(left, right) = pageContent {
            let leading = entry.alignment == .left ? left ?? right : right ?? left
            guard let frame = spreadImageFrame(for: leading) else {
                showUnzoomedPlaceholder()
                return
            }
            entryFrame = frame
        }
        callbackRevision &+= 1
        configuring = true
        if let (focus, frame) = placement {
            handoff?.consumeFocus(for: focus.pageID)
            place(contentPoint: CGPoint(x: frame.minX + focus.point.x * frame.width, y: frame.minY + focus.point.y * frame.height),
                  at: CGPoint(x: bounds.width / 2, y: bounds.height / 2), zoomFactor: focus.factor)
        } else if let entry {
            let startsAtRight = entry.alignment == .right
            let fitsWidth = entryFrame.width * entry.factor <= bounds.width
            let fitsHeight = entryFrame.height * entry.factor <= bounds.height
            place(contentPoint: CGPoint(
                x: fitsWidth ? entryFrame.midX : (startsAtRight ? entryFrame.maxX : entryFrame.minX),
                y: fitsHeight ? entryFrame.midY : entryFrame.minY
            ), at: CGPoint(
                x: fitsWidth ? bounds.width / 2 : (startsAtRight ? bounds.width : 0),
                y: fitsHeight ? bounds.height / 2 : 0
            ), zoomFactor: entry.factor)
        }
        runtime.finishPageEntry()
        configuring = false
        publishNativeState()
    }

    private func spreadImageFrame(for slot: SpreadImage?) -> CGRect? {
        guard let runtime = slot?.runtime, runtime.imageLoaded,
              let image = runtime.nativeSurface as? MangaNativeSurfaceView,
              image.isDescendant(of: zoomContentView), image.baseContentSize != .zero else { return nil }
        return zoomContentView.convert(image.zoomContentView.bounds, from: image.zoomContentView)
    }

    private func notifySpreadOfReadyImage() {
        guard case .image = geometry, runtime?.imageLoaded == true, baseContentSize != .zero else { return }
        var ancestor = superview
        while let view = ancestor {
            if let spread = view as? MangaNativeSurfaceView, case .spread = spread.pageContent {
                if spread.runtime?.pendingPageEntry != nil || spread.handoff?.focusToRestore != nil {
                    spread.applyPendingPageEntry()
                }
                return
            }
            ancestor = view.superview
        }
    }

    private func showUnzoomedPlaceholder() {
        guard !configuring, normalizedZoomFactor > 1 else { return }
        configuring = true
        resetZoom(animated: false)
        placeAtRest()
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
            runtime?.finishPageEntry()
            if MangaPageZoomPolicy.isZoomedForDoubleTapReset(normalizedZoomFactor) {
                let resting = geometry.nativeImageFrame(MangaSurfaceTransform())
                zoom(factor: 1, centeredAt: CGPoint(x: bounds.width / 2 - resting.minX,
                                                   y: bounds.height / 2 - resting.minY), animated: animated)
            } else {
                let local = CGPoint(x: point.x + bounds.minX, y: point.y + bounds.minY)
                zoom(factor: MangaPageZoomPolicy.doubleTapTargetScale,
                     centeredAt: convert(local, to: zoomContentView), animated: animated)
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
        runtime.recordNativeZoom(value.factor)
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
            runtime?.receiveNative(transform, interacting: value.isInteracting, driven: value.isDrivenTransform, instance: self.instance)
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

extension NativeZoomScrollView {
    func remoteTransform(at windowPoint: CGPoint, canZoom: Bool,
                         isCurrent: @escaping () -> Bool) -> ReaderRemoteTransform? {
        guard let window, baseContentSize != .zero else { return nil }
        let point = convert(windowPoint, from: window)
        let anchor = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        let contentPoint = convert(point, to: zoomContentView)
        let factor = normalizedZoomFactor
        let size = baseContentSize
        setDrivenTransformActive(true)
        let valid = { [weak self] in self?.baseContentSize == size && isCurrent() }
        return ReaderRemoteTransform(isCurrent: valid, update: { [weak self] ratio, delta in
            guard let self, valid(), ratio.isFinite, ratio > 0 else { return }
            self.place(contentPoint: contentPoint, at: CGPoint(x: anchor.x + delta.x, y: anchor.y + delta.y),
                       zoomFactor: factor * (canZoom ? ratio : 1))
        }, pan: { [weak self] delta in
            guard let self, valid(),
                  MangaPageZoomPolicy.isActive(self.normalizedZoomFactor) else { return }
            let offset = CGPoint(x: self.contentOffset.x - delta.x, y: self.contentOffset.y - delta.y)
            self.setContentOffset(self.clampedOffset(offset), animated: false)
        }, finish: { [weak self] in
            self?.setDrivenTransformActive(false)
        })
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

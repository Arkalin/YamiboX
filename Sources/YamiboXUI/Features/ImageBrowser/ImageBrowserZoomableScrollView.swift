#if os(iOS)
import SwiftUI
import UIKit

enum ImageBrowserZoomMath {
    static let maximumZoomFactor: CGFloat = 5
    static let doubleTapZoomFactor: CGFloat = 2.6
    static let accessibilityZoomStep: CGFloat = 1.6

    static func fitScale(imageSize: CGSize, containerSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return 1
        }
        return min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    }

    static func normalizedFactor(zoomScale: CGFloat, fitScale: CGFloat) -> CGFloat {
        guard fitScale > 0 else { return 1 }
        return zoomScale / fitScale
    }

    static func clampedFactor(_ factor: CGFloat) -> CGFloat {
        min(maximumZoomFactor, max(1, factor))
    }

    static func doubleTapZoomRect(
        tapPoint: CGPoint,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        let targetScale = fitScale(imageSize: imageSize, containerSize: containerSize) * doubleTapZoomFactor
        guard targetScale > 0 else { return .zero }
        let size = CGSize(
            width: containerSize.width / targetScale,
            height: containerSize.height / targetScale
        )
        return CGRect(
            x: tapPoint.x - size.width / 2,
            y: tapPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func steppedFactor(from factor: CGFloat, zoomIn: Bool) -> CGFloat {
        clampedFactor(zoomIn ? factor * accessibilityZoomStep : factor / accessibilityZoomStep)
    }

    static func isEngagedZoom(factor: CGFloat) -> Bool {
        factor > 1.01
    }

    static func centeringInsets(contentSize: CGSize, containerSize: CGSize) -> UIEdgeInsets {
        let horizontal = max((containerSize.width - contentSize.width) / 2, 0)
        let vertical = max((containerSize.height - contentSize.height) / 2, 0)
        return UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

@MainActor
final class ImageBrowserZoomProxy {
    fileprivate weak var view: ImageBrowserZoomScrollView?

    nonisolated init() {}

    func stepZoom(zoomIn: Bool) {
        view?.stepZoom(zoomIn: zoomIn)
    }

    func resetZoom(animated: Bool) {
        view?.resetZoom(animated: animated)
    }
}

struct ImageBrowserZoomableScrollView: UIViewRepresentable {
    let image: UIImage?
    let animationFrame: UIImage?
    let proxy: ImageBrowserZoomProxy
    let onSingleTap: () -> Void
    let onZoomFactorChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ImageBrowserZoomScrollView {
        let view = ImageBrowserZoomScrollView()
        view.configure(image: image)
        view.displayFrame(animationFrame)
        applyCallbacks(to: view)
        return view
    }

    func updateUIView(_ uiView: ImageBrowserZoomScrollView, context: Context) {
        applyCallbacks(to: uiView)
        if uiView.currentImage !== image {
            uiView.configure(image: image)
        }
        uiView.displayFrame(animationFrame)
    }

    private func applyCallbacks(to view: ImageBrowserZoomScrollView) {
        view.onSingleTap = onSingleTap
        view.onZoomFactorChange = onZoomFactorChange
        proxy.view = view
    }
}

final class ImageBrowserZoomScrollView: NativeZoomScrollView {
    var onSingleTap: (() -> Void)?
    var onZoomFactorChange: ((CGFloat) -> Void)?
    private(set) var currentImage: UIImage?

    private let imageView = UIImageView()
    private var lastLayoutSize: CGSize = .zero
    override init() {
        super.init()
        zoomContentView.addSubview(imageView)
        onSnapshotChange = { [weak self] _ in self?.reportZoomFactor() }
        onViewportSizeChange = { [weak self] _, previous in
            self?.configureImageGeometry(preserving: previous)
        }

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(image: UIImage?) {
        currentImage = image
        imageView.image = image
        let size = image?.size ?? .zero
        imageView.frame = CGRect(origin: .zero, size: size)
        lastLayoutSize = .zero
        setNeedsLayout()
    }

    func displayFrame(_ frame: UIImage?) {
        let displayed = frame ?? currentImage
        guard imageView.image !== displayed else { return }
        imageView.image = displayed
    }

    func stepZoom(zoomIn: Bool) {
        callbackScheduler.performViewUpdate {
            let factor = ImageBrowserZoomMath.normalizedFactor(zoomScale: zoomScale, fitScale: minimumZoomScale)
            let next = ImageBrowserZoomMath.steppedFactor(from: factor, zoomIn: zoomIn)
            setZoomScale(minimumZoomScale * next, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize { configureImageGeometry(preserving: nil) }
    }

    private func configureImageGeometry(preserving previous: NativeZoomSnapshot?) {
        guard let image = currentImage, bounds.width > 0, bounds.height > 0 else { return }
        callbackScheduler.performViewUpdate {
            let hadLayout = lastLayoutSize != .zero
            lastLayoutSize = bounds.size
            let fit = ImageBrowserZoomMath.fitScale(imageSize: image.size, containerSize: bounds.size)
            configureGeometry(contentSize: image.size, minimumScale: fit,
                              maximumFactor: ImageBrowserZoomMath.maximumZoomFactor)
            if hadLayout, let previous {
                place(contentPoint: CGPoint(x: previous.visibleRect.midX, y: previous.visibleRect.midY),
                      at: CGPoint(x: bounds.width / 2, y: bounds.height / 2))
            } else if !hadLayout {
                resetZoom(animated: false)
            }
            reportZoomFactor()
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let image = currentImage else { return }
        let animated = !UIAccessibility.isReduceMotionEnabled
        let factor = ImageBrowserZoomMath.normalizedFactor(zoomScale: zoomScale, fitScale: minimumZoomScale)
        if factor > 1.05 {
            setZoomScale(minimumZoomScale, animated: animated)
        } else {
            let rect = ImageBrowserZoomMath.doubleTapZoomRect(
                tapPoint: recognizer.location(in: imageView),
                imageSize: image.size,
                containerSize: bounds.size
            )
            zoom(to: rect, animated: animated)
        }
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard super.gestureRecognizerShouldBegin(gestureRecognizer) else { return false }
        guard gestureRecognizer === panGestureRecognizer else { return true }
        return ImageBrowserZoomMath.isEngagedZoom(
            factor: ImageBrowserZoomMath.normalizedFactor(zoomScale: zoomScale, fitScale: minimumZoomScale)
        )
    }

    private func reportZoomFactor() {
        guard let onZoomFactorChange else { return }
        let factor = ImageBrowserZoomMath.normalizedFactor(zoomScale: zoomScale, fitScale: minimumZoomScale)
        callbackScheduler.publish {
            onZoomFactorChange(factor)
        }
    }
}
#endif

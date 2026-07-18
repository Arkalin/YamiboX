#if os(iOS)
import SwiftUI
import UIKit

/// Pure math shared by the zoom container and its tests. Zoom is expressed as
/// a factor normalized against the aspect-fit scale: 1 = the image exactly
/// fits the container, `maximumZoomFactor` = 5× past fit — the same scale
/// space the previous pure-SwiftUI implementation used, so
/// `ImageBrowserSwipeDismissGesture` keeps receiving unchanged values.
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

    /// The rect in natural-image coordinates that `UIScrollView.zoom(to:)`
    /// should target so a double tap ends at `doubleTapZoomFactor`, centered
    /// on the tapped image point.
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

    /// Insets that keep undersized content centered in the container — the
    /// standard `UIScrollView` centering trick, applied on zoom and layout.
    static func centeringInsets(contentSize: CGSize, containerSize: CGSize) -> UIEdgeInsets {
        let horizontal = max((containerSize.width - contentSize.width) / 2, 0)
        let vertical = max((containerSize.height - contentSize.height) / 2, 0)
        return UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

/// Commands the zoom container from SwiftUI (accessibility zoom actions and
/// resetting zoom when a page is swiped away) without rebuilding the view.
@MainActor
final class ImageBrowserZoomProxy {
    fileprivate weak var view: ImageBrowserZoomScrollView?

    /// Nonisolated so the proxy can serve as a `@State` default value, which
    /// SwiftUI evaluates outside the main actor.
    nonisolated init() {}

    func stepZoom(zoomIn: Bool) {
        view?.stepZoom(zoomIn: zoomIn)
    }

    func resetZoom(animated: Bool) {
        view?.resetZoom(animated: animated)
    }
}

/// `UIScrollView`-backed zoomable image page: anchored pinch zoom,
/// rubber-banding past the limits, deceleration on pan flicks and double-tap
/// zoom at the tapped point all come from the scroll view itself — feel the
/// pure-SwiftUI gesture stack this replaced could not reproduce. At minimum
/// zoom the scroll view has nothing to scroll, so vertical drags fall through
/// to the SwiftUI swipe-to-dismiss gesture and horizontal swipes to
/// `TabView(.page)`; once zoomed in, its pan takes over and pans the content,
/// handing off to the pager only at the content edge.
struct ImageBrowserZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    let proxy: ImageBrowserZoomProxy
    let onSingleTap: () -> Void
    let onZoomFactorChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ImageBrowserZoomScrollView {
        let view = ImageBrowserZoomScrollView()
        view.configure(image: image)
        applyCallbacks(to: view)
        return view
    }

    func updateUIView(_ uiView: ImageBrowserZoomScrollView, context: Context) {
        applyCallbacks(to: uiView)
        if uiView.currentImage !== image {
            uiView.configure(image: image)
        }
    }

    private func applyCallbacks(to view: ImageBrowserZoomScrollView) {
        view.onSingleTap = onSingleTap
        view.onZoomFactorChange = onZoomFactorChange
        proxy.view = view
    }
}

final class ImageBrowserZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    var onZoomFactorChange: ((CGFloat) -> Void)?
    private(set) var currentImage: UIImage?

    private let imageView = UIImageView()
    private var lastLayoutSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        bounces = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        scrollsToTop = false
        backgroundColor = .clear
        addSubview(imageView)

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

    func configure(image: UIImage) {
        currentImage = image
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        lastLayoutSize = .zero
        setNeedsLayout()
    }

    func stepZoom(zoomIn: Bool) {
        let factor = ImageBrowserZoomMath.normalizedFactor(zoomScale: zoomScale, fitScale: minimumZoomScale)
        let next = ImageBrowserZoomMath.steppedFactor(from: factor, zoomIn: zoomIn)
        setZoomScale(minimumZoomScale * next, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func resetZoom(animated: Bool) {
        setZoomScale(minimumZoomScale, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = currentImage, bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != lastLayoutSize {
            // Preserve the user's zoom factor relative to fit across container
            // size changes (rotation, split view), re-fitting on first layout.
            let previousFactor = ImageBrowserZoomMath.normalizedFactor(
                zoomScale: zoomScale,
                fitScale: minimumZoomScale
            )
            let hadLayout = lastLayoutSize != .zero
            lastLayoutSize = bounds.size

            let fit = ImageBrowserZoomMath.fitScale(imageSize: image.size, containerSize: bounds.size)
            minimumZoomScale = fit
            maximumZoomScale = fit * ImageBrowserZoomMath.maximumZoomFactor
            let factor = hadLayout ? ImageBrowserZoomMath.clampedFactor(previousFactor) : 1
            zoomScale = fit * factor
            reportZoomFactor()
        }
        recenterContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        recenterContent()
        reportZoomFactor()
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

    private func recenterContent() {
        contentInset = ImageBrowserZoomMath.centeringInsets(
            contentSize: contentSize,
            containerSize: bounds.size
        )
    }

    private func reportZoomFactor() {
        onZoomFactorChange?(
            ImageBrowserZoomMath.normalizedFactor(zoomScale: zoomScale, fitScale: minimumZoomScale)
        )
    }
}
#endif

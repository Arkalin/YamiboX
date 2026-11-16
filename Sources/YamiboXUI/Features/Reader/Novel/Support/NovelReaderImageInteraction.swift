import UIKit
import UIKit.UIGestureRecognizerSubclass
import YamiboXCore

/// Shared hit testing and event delivery; each viewport retains its own gestures
/// and callback scheduler. No interaction state is shared between reader sessions.
@MainActor
enum NovelReaderImageInteraction {
    static func activateFailureControl(at point: CGPoint, in window: UIWindow,
                                       device: ReaderDeviceInteractionContext?) -> Bool {
        guard let action = window.readerHit(NovelReaderVerticalViewportImageView.self, at: point, in: window,
            resolve: { view, _ in view.remoteFailureAction(at: point, in: window, device: device) }) else { return false }
        action()
        return true
    }

    static func image(at point: CGPoint, in window: UIWindow) -> (url: URL, title: String?)? {
        window.readerHit(NovelReaderVerticalViewportImageView.self, at: point, in: window,
                         resolve: { $0.imageTapPayloadIfHit(at: $1) })
    }

    static func installDoubleTap(
        in viewport: UIView,
        singleTap: UITapGestureRecognizer,
        canOpen: @escaping () -> Bool,
        onOpen: @escaping (URL, String?) -> Void
    ) {
        let doubleTap = NovelReaderImageDoubleTapRecognizer(canOpen: canOpen, onOpen: onOpen)
        viewport.addGestureRecognizer(doubleTap)
        singleTap.require(toFail: doubleTap)
    }

    static func longPress(
        _ recognizer: UILongPressGestureRecognizer,
        surfaces: [NovelReaderSurface],
        scheduler: SwiftUIViewUpdateCallbackScheduler,
        onImageLongPress: @escaping (NovelImageLikeAnchor, URL, String?) -> Void
    ) {
        guard recognizer.state == .began, let container = recognizer.view else { return }
        let location = recognizer.location(in: container)
        guard let imageView = container.firstDescendant(
            ofType: NovelReaderVerticalViewportImageView.self,
            containing: location
        ), let payload = imageView.imageTapPayloadIfHit(
            at: container.convert(location, to: imageView)
        ), let anchor = novelImageLikeAnchor(forImageURL: payload.url, in: surfaces) else {
            return
        }
        scheduler.publish { onImageLongPress(anchor, payload.url, payload.title) }
    }
}

/// Keep UIKit's tap timing and movement tolerance, but fail immediately outside
/// a loaded image so ordinary reader taps never wait for a second tap there.
@MainActor
final class NovelReaderImageDoubleTapRecognizer: UITapGestureRecognizer {
    private let canOpen: () -> Bool
    private let onOpen: (URL, String?) -> Void
    private weak var firstImageView: NovelReaderVerticalViewportImageView?
    private var firstSource: YamiboImageSource?
    private var firstTitle: String?

    init(canOpen: @escaping () -> Bool, onOpen: @escaping (URL, String?) -> Void) {
        self.canOpen = canOpen
        self.onOpen = onOpen
        super.init(target: nil, action: nil)
        numberOfTapsRequired = 2
        cancelsTouchesInView = false
        addTarget(self, action: #selector(openImage))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let scrollView = view as? UIScrollView
        guard canOpen(), scrollView?.isDragging != true, scrollView?.isDecelerating != true,
              touches.count == 1, let touch = touches.first,
              touch.view?.isDescendant(ofType: UIControl.self) != true,
              let (imageView, payload) = hit(at: touch),
              let source = imageView.sourceIdentity else {
            state = .failed
            return
        }
        if firstSource == nil {
            firstImageView = imageView
            firstSource = source
            firstTitle = payload.title
        } else if !matchesFirstImage(imageView, title: payload.title) {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard canOpen(), touches.count == 1, let touch = touches.first,
              let (imageView, payload) = hit(at: touch),
              matchesFirstImage(imageView, title: payload.title) else {
            state = .failed
            return
        }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        firstImageView = nil
        firstSource = nil
        firstTitle = nil
        super.reset()
    }

    private func hit(at touch: UITouch) -> (NovelReaderVerticalViewportImageView, (url: URL, title: String?))? {
        guard let view, let window = view.window else { return nil }
        return view.readerHit(NovelReaderVerticalViewportImageView.self, at: touch.location(in: window), in: window) {
            imageView, point in
            imageView.imageTapPayloadIfHit(at: point).map { (imageView, $0) }
        }
    }

    private func matchesFirstImage(_ imageView: NovelReaderVerticalViewportImageView, title: String?) -> Bool {
        imageView === firstImageView && imageView.sourceIdentity == firstSource && title == firstTitle
    }

    @objc private func openImage() {
        guard state == .ended, canOpen(), let imageView = firstImageView,
              let view, imageView.isDescendant(of: view), imageView.window != nil,
              let payload = imageView.imageTapPayloadIfHit(at: location(in: imageView)),
              matchesFirstImage(imageView, title: payload.title) else { return }
        onOpen(payload.url, payload.title)
    }
}

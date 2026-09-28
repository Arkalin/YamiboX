import UIKit
import YamiboXCore

/// Shared hit testing and event delivery; each viewport retains its own gestures
/// and callback scheduler. No interaction state is shared between reader sessions.
@MainActor
enum NovelReaderImageInteraction {
    static func tap(
        imageView: NovelReaderVerticalViewportImageView,
        at location: CGPoint,
        isChromeVisible: Bool,
        scheduler: SwiftUIViewUpdateCallbackScheduler,
        onChromeVisibleTap: @escaping () -> Void,
        onImageTap: @escaping (URL, String?) -> Void
    ) {
        if isChromeVisible {
            scheduler.publish(onChromeVisibleTap)
            return
        }
        guard let payload = imageView.imageTapPayloadIfHit(at: location) else { return }
        scheduler.publish { onImageTap(payload.url, payload.title) }
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

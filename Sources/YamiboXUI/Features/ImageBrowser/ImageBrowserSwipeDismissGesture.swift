import CoreGraphics

enum ImageBrowserSwipeDismissGesture {
    /// Floor low enough that a decisive short flick can dismiss; it only
    /// guards against twitch-level drags committing by accident.
    static let minimumTranslation: CGFloat = 45
    static let committedTranslation: CGFloat = 150
    /// Seconds of release velocity folded into the projected landing point.
    static let velocityProjectionInterval: CGFloat = 0.15

    static func progress(for translationY: CGFloat) -> CGFloat {
        min(max(translationY / committedTranslation, 0), 1)
    }

    static func imageScale(for progress: CGFloat) -> CGFloat {
        1 - min(max(progress, 0), 1) * 0.08
    }

    static func canBegin(translation: CGPoint, zoomScale: CGFloat, minimumZoomScale: CGFloat) -> Bool {
        guard zoomScale <= minimumZoomScale + 0.01 else { return false }
        guard translation.y > 0 else { return false }
        return translation.y > abs(translation.x) * 1.2
    }

    /// Decides on the projected landing point (position + velocity·τ) rather
    /// than raw position/velocity thresholds: a fast short flick dismisses,
    /// and a drag released while moving back *up* cancels even from far down
    /// — the release velocity's sign matters, not just where the finger is.
    static func shouldDismiss(translation: CGPoint, velocity: CGPoint, zoomScale: CGFloat, minimumZoomScale: CGFloat) -> Bool {
        guard canBegin(translation: translation, zoomScale: zoomScale, minimumZoomScale: minimumZoomScale) else {
            return false
        }
        guard translation.y >= minimumTranslation else { return false }
        let projected = translation.y + velocity.y * velocityProjectionInterval
        return projected >= committedTranslation
    }
}

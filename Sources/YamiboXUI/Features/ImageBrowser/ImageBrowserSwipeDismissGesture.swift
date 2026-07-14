import CoreGraphics

enum ImageBrowserSwipeDismissGesture {
    static let minimumTranslation: CGFloat = 90
    static let committedTranslation: CGFloat = 150
    static let minimumVelocity: CGFloat = 650
    /// Larger than the default `DragGesture` minimum distance (10pt) so a horizontal swipe
    /// between pages loses the recognition race to `TabView(.page)`'s own pan gesture instead
    /// of competing with it for every drag on an unzoomed image.
    static let minimumRecognitionDistance: CGFloat = 20

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

    static func shouldDismiss(translation: CGPoint, velocity: CGPoint, zoomScale: CGFloat, minimumZoomScale: CGFloat) -> Bool {
        guard canBegin(translation: translation, zoomScale: zoomScale, minimumZoomScale: minimumZoomScale) else {
            return false
        }
        guard translation.y >= minimumTranslation else { return false }
        return translation.y >= committedTranslation || velocity.y >= minimumVelocity
    }
}

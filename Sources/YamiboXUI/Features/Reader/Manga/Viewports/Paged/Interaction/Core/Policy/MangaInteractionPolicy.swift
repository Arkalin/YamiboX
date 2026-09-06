import Foundation

enum PhysicalZone: Equatable { case left, center, right }
enum NavigationStep: Int { case backward = -1, forward = 1 }
struct SurfaceID: Hashable { let value: String }

enum MangaInteractionIntent {
    case pan(translation: CGSize, velocity: CGSize)
    case edge(MangaPagedImageSurfaceHorizontalEdge)
    case doubleTap(CGPoint)
    case longPress(CGPoint)
    case centerTap
}

enum MangaInteractionDecision: Equatable {
    case panImage
    case navigate(MangaPagedImageSurfaceHorizontalEdge)
    case reveal(MangaPagedImageSurfaceHorizontalEdge)
    case zoom(CGPoint)
    case menu
    case toggleChrome
    case ignore
}

struct MangaInteractionConfiguration: Equatable {
    var chromeVisible = false
    var zoomEnabled = true
    var allowsUnzoomedPan = true
}

enum MangaInteractionPolicy {
    static func dragEdge(translation: CGSize, velocity: CGSize) -> MangaPagedImageSurfaceHorizontalEdge? {
        let vector = velocity == .zero ? translation : velocity
        guard vector.width != 0, abs(vector.width) > abs(vector.height) else { return nil }
        return vector.width < 0 ? .right : .left
    }

    static func decide(
        _ intent: MangaInteractionIntent,
        configuration: MangaInteractionConfiguration,
        scale: CGFloat,
        hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge>,
        menuFrame: CGRect,
        imageLoaded: Bool
    ) -> MangaInteractionDecision {
        switch intent {
        case .centerTap:
            return .toggleChrome
        case let .longPress(point):
            return imageLoaded && !menuFrame.isEmpty && menuFrame.contains(point) ? .menu : .ignore
        case let .doubleTap(point):
            if configuration.chromeVisible { return .toggleChrome }
            return configuration.zoomEnabled && imageLoaded ? .zoom(point) : .ignore
        case let .edge(edge):
            if configuration.chromeVisible { return .toggleChrome }
            return imageLoaded && hiddenEdges.contains(edge) ? .reveal(edge) : .navigate(edge)
        case let .pan(translation, velocity):
            guard !configuration.chromeVisible else { return .ignore }
            if imageLoaded && MangaPageZoomPolicy.isActive(scale) { return .panImage }
            guard let edge = dragEdge(translation: translation, velocity: velocity) else { return .ignore }
            if imageLoaded && configuration.allowsUnzoomedPan && hiddenEdges.contains(edge) {
                return .panImage
            }
            return .navigate(edge)
        }
    }
}

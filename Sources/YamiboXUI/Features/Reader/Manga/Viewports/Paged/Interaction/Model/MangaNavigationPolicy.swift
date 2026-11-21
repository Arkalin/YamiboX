import Foundation
import YamiboXCore

enum MangaReadingDirection {
    case leftToRight, rightToLeft

    func step(toward edge: MangaPagedImageSurfaceHorizontalEdge) -> NavigationStep {
        (edge == .right) == (self == .leftToRight) ? .forward : .backward
    }

    func edge(for step: NavigationStep) -> MangaPagedImageSurfaceHorizontalEdge {
        (step == .forward) == (self == .leftToRight) ? .right : .left
    }
}

struct MangaNavigationConfiguration: Equatable {
    let direction: MangaReadingDirection
    let surface: MangaInteractionConfiguration
    var gestureRegionLayout: ReaderGestureRegionLayout = .classic

    func allowsDoubleTap(at point: CGPoint, in bounds: CGRect) -> Bool {
        guard let action = gestureRegionLayout.action(at: point, in: bounds) else { return false }
        return action == .toggleChrome || (surface.zoomEnabled && surface.doubleTapZoomEnabled)
    }

    func tap(at point: CGPoint, in bounds: CGRect) -> MangaNavigationRequest? {
        guard let action = gestureRegionLayout.action(at: point, in: bounds) else { return nil }
        let x = point.x - bounds.minX
        let third = bounds.width / 3
        let revealEdge: MangaPagedImageSurfaceHorizontalEdge? = x < third ? .left :
            (x > third * 2 ? .right : nil)
        return .tap(action, revealEdge: revealEdge)
    }
}

enum MangaNavigationRequest {
    case tap(ReaderGestureRegionAction, revealEdge: MangaPagedImageSurfaceHorizontalEdge?)
    case doubleTap(CGPoint)
    case control(NavigationStep)
    case pan(translation: CGSize, velocity: CGSize)

    func intent(direction: MangaReadingDirection) -> MangaInteractionIntent {
        switch self {
        case .tap(.toggleChrome, _): .menuTap
        case let .tap(action, revealEdge):
            .pageTap(target: direction.edge(for: action == .previous ? .backward : .forward), reveal: revealEdge)
        case let .doubleTap(location): .doubleTap(location)
        case let .control(step): .control(direction.edge(for: step))
        case let .pan(translation, velocity): .pan(translation: translation, velocity: velocity)
        }
    }
}

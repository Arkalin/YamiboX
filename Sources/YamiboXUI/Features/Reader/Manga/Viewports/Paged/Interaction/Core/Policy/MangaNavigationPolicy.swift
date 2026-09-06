import Foundation

extension PhysicalZone {
    static func at(_ point: CGPoint, in bounds: CGRect) -> Self? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        let x = point.x - bounds.minX
        if x < bounds.width / 3 { return .left }
        if x > bounds.width * 2 / 3 { return .right }
        return .center
    }
}

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
}

enum MangaNavigationRequest {
    case tap(PhysicalZone?)
    case doubleTap(zone: PhysicalZone?, location: CGPoint)
    case control(NavigationStep)
    case pan(translation: CGSize, velocity: CGSize)

    func intent(direction: MangaReadingDirection) -> MangaInteractionIntent? {
        switch self {
        case .tap(.left): .edge(.left)
        case .tap(.right): .edge(.right)
        case .tap(.center): .centerTap
        case let .doubleTap(.center, location): .doubleTap(location)
        case let .control(step): .control(direction.edge(for: step))
        case let .pan(translation, velocity): .pan(translation: translation, velocity: velocity)
        case .tap(nil), .doubleTap: nil
        }
    }
}

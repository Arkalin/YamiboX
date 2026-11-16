import Foundation

public enum ReaderGestureRegionAction: Hashable, Sendable {
    case previous
    case toggleChrome
    case next
}

public enum ReaderGestureRegionLayout: String, Codable, CaseIterable, Hashable, Sendable {
    case classic
    case kindle
    case lShape
    case bothSidesAdvance

    public var title: String {
        L10n.string("reader.gesture_regions.\(rawValue)")
    }

    // Each region is connected, with disjoint rectangles in a 3 × 3 grid.
    // The first rectangle provides the label position.
    package struct Region {
        package let action: ReaderGestureRegionAction
        package let rectangles: [CGRect]

        fileprivate init(_ action: ReaderGestureRegionAction, _ rectangles: CGRect...) {
            self.action = action
            self.rectangles = rectangles
        }
    }

    package var regions: [Region] {
        switch self {
        case .classic:
            [.init(.previous, grid(0, 0, 1, 3)),
             .init(.toggleChrome, grid(1, 0, 1, 3)),
             .init(.next, grid(2, 0, 1, 3))]
        case .kindle:
            [.init(.toggleChrome, grid(0, 0, 3, 1)),
             .init(.previous, grid(0, 1, 1, 2)),
             .init(.next, grid(1, 1, 2, 2))]
        case .lShape:
            [.init(.previous, grid(0, 0, 3, 1), grid(0, 1, 1, 1)),
             .init(.toggleChrome, grid(1, 1, 1, 1)),
             .init(.next, grid(0, 2, 3, 1), grid(2, 1, 1, 1))]
        case .bothSidesAdvance:
            [.init(.next, grid(0, 0, 1, 3)),
             .init(.toggleChrome, grid(1, 0, 1, 2)),
             .init(.next, grid(2, 0, 1, 3)),
             .init(.previous, grid(1, 2, 1, 1))]
        }
    }

    package func action(at point: CGPoint, in bounds: CGRect) -> ReaderGestureRegionAction? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        let position = CGPoint(x: (point.x - bounds.minX) / bounds.width * 3,
                               y: (point.y - bounds.minY) / bounds.height * 3)
        return regions.first { region in
            region.rectangles.contains { $0.contains(position) }
        }?.action
    }

    private func grid(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

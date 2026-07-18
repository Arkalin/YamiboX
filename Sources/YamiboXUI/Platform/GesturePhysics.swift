import CoreGraphics
import SwiftUI

/// Gesture physics shared by the pan/zoom surfaces (manga reader, image
/// browser, favorites background editor), following Apple's "Designing Fluid
/// Interfaces": boundaries resist progressively instead of stopping hard,
/// releases project momentum forward, and the settle animation continues at
/// the finger's speed so there is no seam between dragging and animating.
enum GesturePhysics {
    /// `UIScrollView`-style deceleration factors (per millisecond).
    enum DecelerationRate {
        static let normal: CGFloat = 0.998
        static let fast: CGFloat = 0.99
    }

    /// Where a value moving at `velocity` (points/second) coasts to a stop
    /// under exponential decay. Apple's exact projection function from the
    /// Fluid Interfaces sample code.
    static func project(
        _ velocity: CGFloat,
        decelerationRate: CGFloat = DecelerationRate.normal
    ) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    static func project(
        _ velocity: CGSize,
        decelerationRate: CGFloat = DecelerationRate.normal
    ) -> CGSize {
        CGSize(
            width: project(velocity.width, decelerationRate: decelerationRate),
            height: project(velocity.height, decelerationRate: decelerationRate)
        )
    }

    /// Attenuates the portion of `value` outside `lower...upper` with the
    /// classic scroll-view rubber-band curve, so an edge reads as "responsive,
    /// but there's nothing more here" rather than a wall. `dimension` is the
    /// visible extent along the axis.
    static func rubberBanded(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat,
        dimension: CGFloat,
        coefficient: CGFloat = 0.55
    ) -> CGFloat {
        guard lower <= upper else { return value }
        guard dimension > 0 else { return min(upper, max(lower, value)) }
        if value > upper {
            return upper + attenuated(value - upper, dimension: dimension, coefficient: coefficient)
        }
        if value < lower {
            return lower - attenuated(lower - value, dimension: dimension, coefficient: coefficient)
        }
        return value
    }

    private static func attenuated(
        _ overshoot: CGFloat,
        dimension: CGFloat,
        coefficient: CGFloat
    ) -> CGFloat {
        (overshoot * dimension * coefficient) / (dimension + coefficient * overshoot)
    }

    /// The release velocity expressed the way spring animations expect it:
    /// as a fraction of the remaining distance per second. 2D variant takes
    /// the velocity component along the direction of travel.
    static func relativeVelocity(
        _ velocity: CGSize,
        from current: CGSize,
        to target: CGSize
    ) -> CGFloat {
        let delta = CGSize(width: target.width - current.width, height: target.height - current.height)
        let distanceSquared = delta.width * delta.width + delta.height * delta.height
        guard distanceSquared > 1 else { return 0 }
        let along = velocity.width * delta.width + velocity.height * delta.height
        return clampedRelativeVelocity(along / distanceSquared)
    }

    static func relativeVelocity(
        _ velocity: CGFloat,
        from current: CGFloat,
        to target: CGFloat
    ) -> CGFloat {
        let delta = target - current
        guard abs(delta) > 0.0001 else { return 0 }
        return clampedRelativeVelocity(velocity / delta)
    }

    /// A runaway relative velocity (tiny remaining distance, fast finger)
    /// would kick the spring absurdly hard; cap it to keep settles composed.
    private static func clampedRelativeVelocity(_ value: CGFloat) -> CGFloat {
        min(30, max(-30, value))
    }
}

extension Animation {
    /// Critically damped settle for discrete, non-momentum changes
    /// (double-tap zoom, reveal, reset) — Apple's "move/reposition" spring.
    static var gestureSettle: Animation {
        .spring(response: 0.38, dampingFraction: 1.0)
    }

    /// Continues a released drag/flick at the finger's speed. Slightly
    /// under-damped because momentum preceded it.
    static func gestureMomentum(initialVelocity: CGFloat) -> Animation {
        .interpolatingSpring(
            Spring(response: 0.4, dampingRatio: 0.86),
            initialVelocity: initialVelocity
        )
    }
}

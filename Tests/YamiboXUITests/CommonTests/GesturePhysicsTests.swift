import CoreGraphics
import Testing
@testable import YamiboXUI

@Suite("CommonTests: Gesture Physics")
struct GesturePhysicsTests {
    @Test func projectionMatchesExponentialDecayForm() {
        // (v / 1000) * rate / (1 - rate)
        #expect(abs(GesturePhysics.project(1000) - 499) < 0.001)
        #expect(abs(GesturePhysics.project(1000, decelerationRate: 0.99) - 99) < 0.001)
        #expect(GesturePhysics.project(0) == 0)
        #expect(GesturePhysics.project(-500) < 0)
    }

    @Test func rubberBandPassesThroughValuesInsideBounds() {
        #expect(GesturePhysics.rubberBanded(50, lower: -100, upper: 100, dimension: 400) == 50)
        #expect(GesturePhysics.rubberBanded(-100, lower: -100, upper: 100, dimension: 400) == -100)
        #expect(GesturePhysics.rubberBanded(100, lower: -100, upper: 100, dimension: 400) == 100)
    }

    @Test func rubberBandAttenuatesOvershootProgressively() {
        let smallOvershoot = GesturePhysics.rubberBanded(150, lower: -100, upper: 100, dimension: 400)
        let largeOvershoot = GesturePhysics.rubberBanded(300, lower: -100, upper: 100, dimension: 400)

        // Beyond the bound, displacement is attenuated but monotonic.
        #expect(smallOvershoot > 100)
        #expect(smallOvershoot < 150)
        #expect(largeOvershoot > smallOvershoot)

        // Marginal give shrinks the further past the bound the finger drags.
        let firstStep = smallOvershoot - 100
        let secondStep = largeOvershoot - smallOvershoot
        #expect(secondStep < firstStep * 3.1) // 150pt more raw travel, less than proportional give
        #expect(largeOvershoot - 100 < 200 * 0.55 + 1) // never exceeds the coefficient ceiling
    }

    @Test func rubberBandIsSymmetricBelowLowerBound() {
        let above = GesturePhysics.rubberBanded(180, lower: -100, upper: 100, dimension: 400)
        let below = GesturePhysics.rubberBanded(-180, lower: -100, upper: 100, dimension: 400)
        #expect(abs((above - 100) - (-100 - below)) < 0.0001)
    }

    @Test func rubberBandFallsBackToClampForDegenerateDimension() {
        #expect(GesturePhysics.rubberBanded(180, lower: -100, upper: 100, dimension: 0) == 100)
        #expect(GesturePhysics.rubberBanded(-180, lower: -100, upper: 100, dimension: 0) == -100)
    }

    @Test func scalarRelativeVelocityNormalizesByRemainingDistance() {
        // 50 pt/s toward a target 100 pt away → half the distance per second.
        #expect(abs(GesturePhysics.relativeVelocity(50, from: 0, to: 100) - 0.5) < 0.0001)
        // Moving away from the target yields a negative kick.
        #expect(GesturePhysics.relativeVelocity(-50, from: 0, to: 100) < 0)
        // Zero remaining distance must not blow up.
        #expect(GesturePhysics.relativeVelocity(500, from: 100, to: 100) == 0)
        // Runaway ratios are capped.
        #expect(GesturePhysics.relativeVelocity(10_000, from: 0, to: 1) == 30)
    }

    @Test func vectorRelativeVelocityUsesComponentAlongTravel() {
        let current = CGSize.zero
        let target = CGSize(width: 100, height: 0)

        // Velocity fully along the travel direction.
        let along = GesturePhysics.relativeVelocity(
            CGSize(width: 50, height: 0), from: current, to: target
        )
        #expect(abs(along - 0.5) < 0.0001)

        // Perpendicular velocity contributes nothing.
        let perpendicular = GesturePhysics.relativeVelocity(
            CGSize(width: 0, height: 300), from: current, to: target
        )
        #expect(perpendicular == 0)

        // Negligible travel yields zero rather than dividing by ~0.
        let degenerate = GesturePhysics.relativeVelocity(
            CGSize(width: 500, height: 500), from: current, to: CGSize(width: 0.5, height: 0.5)
        )
        #expect(degenerate == 0)
    }
}

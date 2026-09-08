import Testing
@testable import YamiboXUI

struct BookOpeningPressFeedbackTests {
    @Test func quickTapWithoutDeliveredPressStillCompresses() {
        var feedback = BookOpeningPressFeedback()
        feedback.activate(reduceMotion: false)

        #expect(feedback.isActivating)
        #expect(feedback.activationDelay == .milliseconds(120))
    }

    @Test func shortPressOnlyWaitsForRemainingCompression() {
        var feedback = BookOpeningPressFeedback()
        let start = ContinuousClock.now
        feedback.pressChanged(true, now: start)
        feedback.activate(reduceMotion: false, now: start.advanced(by: .milliseconds(40)))
        feedback.pressChanged(false)

        #expect(feedback.activationDelay == .milliseconds(80))
        #expect(feedback.isActivating)
    }

    @Test func sustainedPressDoesNotAddDelay() {
        var feedback = BookOpeningPressFeedback()
        let start = ContinuousClock.now
        feedback.pressChanged(true, now: start)
        feedback.activate(reduceMotion: false, now: start.advanced(by: .milliseconds(300)))

        #expect(feedback.activationDelay == .zero)
    }

    @Test func repeatedActivationDoesNotRestartPendingFeedback() {
        var feedback = BookOpeningPressFeedback()
        let start = ContinuousClock.now
        feedback.activate(reduceMotion: false, now: start)
        feedback.activate(reduceMotion: false, now: start.advanced(by: .milliseconds(50)))

        #expect(feedback.activationDelay == .milliseconds(120))
    }

    @Test func cancelledPressDoesNotActivateOrCarryTimingIntoNextTap() {
        var feedback = BookOpeningPressFeedback()
        let start = ContinuousClock.now
        feedback.pressChanged(true, now: start)
        feedback.pressChanged(false, now: start.advanced(by: .milliseconds(300)))
        #expect(!feedback.isActivating)

        feedback.activate(reduceMotion: false)
        #expect(feedback.activationDelay == .milliseconds(120))
    }

    @Test func resetCancelsPendingActivationAndAllowsNextTap() {
        var feedback = BookOpeningPressFeedback()
        feedback.activate(reduceMotion: false)
        feedback.reset()
        #expect(!feedback.isActivating)
        #expect(feedback.activationDelay == nil)

        feedback.activate(reduceMotion: false)
        #expect(feedback.activationDelay == .milliseconds(120))
    }

    @Test func reduceMotionActivatesWithoutAnimationDelay() {
        var feedback = BookOpeningPressFeedback()
        feedback.activate(reduceMotion: true)

        #expect(feedback.activationDelay == .zero)
    }
}

import Foundation
import Testing
import YamiboXCore
@testable import YamiboXUI

@Suite("Transient failure feedback")
struct TransientFeedbackTests {
    @Test func multipleOwnersChooseNewestFeedbackRatherThanFixedPriority() {
        let old = TransientFeedback.failure("old")
        let recent = TransientFeedback.failure("recent")
        #expect(TransientFeedback.latest(old, recent)?.id == recent.id)
        #expect(TransientFeedback.latest(recent, old)?.id == recent.id)
        #expect(TransientFeedback.latest(old, nil)?.id == old.id)
        #expect(TransientFeedback.latest(nil, recent)?.id == recent.id)
        #expect(TransientFeedback.latest(nil, nil) == nil)
    }

    @Test func imageFeedbackPreservesErrorAndUsesExistingDurationInput() {
        let details = LoadFailureDetails(error: URLError(.timedOut))
        let feedback = MangaImageSaveFeedback.failure(message: "Save failed", details: details)
        #expect(feedback.transientFeedback.details == details)
        #expect(feedback.transientFeedback.id == feedback.id)
        #expect(feedback.transientFeedback.message == feedback.title + feedback.message)
        #expect(MangaImageSaveFeedback.success.details == nil)
        #expect(MangaImageSaveFeedback.success.id != MangaImageSaveFeedback.success.id)
    }

    @Test func preservesExistingDurations() {
        #expect(TransientFeedbackCountdown.duration(for: "short") == .seconds(3))
        #expect(TransientFeedbackCountdown.duration(for: String(repeating: "x", count: 40)) == .seconds(4.8))
        #expect(TransientFeedbackCountdown.duration(for: String(repeating: "x", count: 100)) == .seconds(8))
        #expect(TransientFeedbackCountdown.duration(for: "short", minimumSeconds: 1.8) == .seconds(1.8))
    }

    @Test func pausesAndResumesOnlyRemainingTime() {
        let id = UUID()
        var countdown = TransientFeedbackCountdown()
        countdown.replace(id: id, duration: .seconds(3), now: .zero)
        countdown.pause(id: id, now: .seconds(2))
        #expect(countdown.remaining == .seconds(1))
        #expect(!countdown.canExpire(id: id, now: .seconds(100)))
        countdown.resume(id: id, now: .seconds(100))
        #expect(!countdown.canExpire(id: id, now: .seconds(100.5)))
        #expect(countdown.canExpire(id: id, now: .seconds(101)))
    }

    @Test func repeatedTextGetsNewIdentityAndOldTimerCannotClearIt() {
        let first = TransientFeedback.failure("same")
        let second = TransientFeedback.failure("same")
        #expect(first.id != second.id)
        var countdown = TransientFeedbackCountdown()
        countdown.replace(id: first.id, duration: .seconds(3), now: .zero)
        countdown.pause(id: first.id, now: .seconds(1))
        countdown.replace(id: second.id, duration: .seconds(3), now: .seconds(2))
        countdown.resume(id: first.id, now: .seconds(3))
        countdown.pause(id: first.id, now: .seconds(3))
        #expect(!countdown.canExpire(id: first.id, now: .seconds(10)))
        #expect(!countdown.canExpire(id: second.id, now: .seconds(4)))
        #expect(countdown.canExpire(id: second.id, now: .seconds(5)))
        countdown.replace(id: nil, duration: .zero, now: .seconds(5))
        #expect(!countdown.canExpire(id: second.id, now: .seconds(10)))
    }

    @Test func retainsActualFailureAndDoesNotInferFailureFromText() throws {
        let ordinary = TransientFeedback(message: "0 failures")
        #expect(ordinary.details == nil)
        let failure = try #require(TransientFeedback.failure(URLError(.timedOut), message: "Refresh failed"))
        #expect(failure.message == "Refresh failed")
        #expect(failure.details?.causes.first?.code == URLError.timedOut.rawValue)
        #expect(TransientFeedback.failure(CancellationError()) == nil)
        #expect(TransientFeedback.failure(URLError(.cancelled)) == nil)
        #expect(TransientFeedback.failure("Validation failed").details?.causes.isEmpty == true)
    }
}

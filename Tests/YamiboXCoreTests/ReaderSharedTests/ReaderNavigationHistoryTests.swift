import Testing
@testable import YamiboXCore

@Test func readerNavigationHistoryRecordsNonlinearJumpSources() {
    var history = ReaderNavigationHistory<Int>()

    history.recordNonlinearJump(from: 3, to: 9)

    #expect(history.peekBack() == 3)
    #expect(history.peekForward() == nil)
    #expect(history.canGoBack)
    #expect(!history.canGoForward)
}

@Test func readerNavigationHistorySkipsSameSourceAndTargetWithoutClearingForward() {
    var history = ReaderNavigationHistory<Int>()
    history.recordNonlinearJump(from: 1, to: 5)
    _ = history.commitBack(from: 5)

    history.recordNonlinearJump(from: 1, to: 1)

    #expect(history.peekBack() == nil)
    #expect(history.peekForward() == 5)
}

@Test func readerNavigationHistoryTransfersAnchorsAfterSuccessfulBackAndForwardRestore() {
    var history = ReaderNavigationHistory<Int>()
    history.recordNonlinearJump(from: 1, to: 5)
    history.recordNonlinearJump(from: 5, to: 9)

    #expect(history.peekBack() == 5)
    #expect(history.commitBack(from: 9) == 5)
    #expect(history.peekBack() == 1)
    #expect(history.peekForward() == 9)

    #expect(history.commitForward(from: 5) == 9)
    #expect(history.peekBack() == 5)
    #expect(history.peekForward() == nil)
}

@Test func readerNavigationHistoryDiscardsUnresolvableCandidatesWithoutTransferringCurrentAnchor() {
    var history = ReaderNavigationHistory<Int>()
    history.recordNonlinearJump(from: 1, to: 5)
    history.recordNonlinearJump(from: 5, to: 9)

    #expect(history.discardBackCandidate() == 5)

    #expect(history.peekBack() == 1)
    #expect(history.peekForward() == nil)
}

@Test func readerNavigationHistoryClearsForwardAfterSuccessfulNonlinearBranch() {
    var history = ReaderNavigationHistory<Int>()
    history.recordNonlinearJump(from: 1, to: 5)
    _ = history.commitBack(from: 5)

    history.recordNonlinearJump(from: 1, to: 8)

    #expect(history.peekBack() == 1)
    #expect(history.peekForward() == nil)
}

@Test func readerNavigationHistoryRetainsOnlyNewestAnchorsUpToCapacity() {
    var history = ReaderNavigationHistory<Int>(capacity: 3)

    history.recordNonlinearJump(from: 1, to: 2)
    history.recordNonlinearJump(from: 2, to: 3)
    history.recordNonlinearJump(from: 3, to: 4)
    history.recordNonlinearJump(from: 4, to: 5)

    #expect(history.backStack == [2, 3, 4])
}

@Test func readerNavigationHistoryClearRemovesBackAndForwardStacks() {
    var history = ReaderNavigationHistory<Int>()
    history.recordNonlinearJump(from: 1, to: 5)
    _ = history.commitBack(from: 5)

    history.clear()

    #expect(!history.canGoBack)
    #expect(!history.canGoForward)
    #expect(history.peekBack() == nil)
    #expect(history.peekForward() == nil)
}

@Test func readerNavigationLinearReadingExpirationExpiresAfterThresholdDistinctPagesInOneDirection() {
    var expiration = ReaderNavigationLinearReadingExpiration<Int>(threshold: 5)

    expiration.arm(at: 10)

    let repeatedInitialPageExpired = expiration.recordLinearReading(at: 10, direction: .forward)
    let firstPageExpired = expiration.recordLinearReading(at: 11, direction: .forward)
    let repeatedFirstPageExpired = expiration.recordLinearReading(at: 11, direction: .forward)
    let secondPageExpired = expiration.recordLinearReading(at: 12, direction: .forward)
    let thirdPageExpired = expiration.recordLinearReading(at: 13, direction: .forward)
    let fourthPageExpired = expiration.recordLinearReading(at: 14, direction: .forward)
    let fifthPageExpired = expiration.recordLinearReading(at: 15, direction: .forward)

    #expect(!repeatedInitialPageExpired)
    #expect(!firstPageExpired)
    #expect(!repeatedFirstPageExpired)
    #expect(!secondPageExpired)
    #expect(!thirdPageExpired)
    #expect(!fourthPageExpired)
    #expect(fifthPageExpired)
    #expect(!expiration.isArmed)
}

@Test func readerNavigationLinearReadingExpirationRestartsStreakWhenDirectionReverses() {
    var expiration = ReaderNavigationLinearReadingExpiration<Int>(threshold: 5)

    expiration.arm(at: 10)

    // Three steps forward, then reverse: the reversal restarts the streak,
    // so a full five more same-direction steps are needed to reach the
    // threshold, not just the two remaining from the original streak.
    _ = expiration.recordLinearReading(at: 11, direction: .forward)
    _ = expiration.recordLinearReading(at: 12, direction: .forward)
    _ = expiration.recordLinearReading(at: 13, direction: .forward)
    let reversalExpired = expiration.recordLinearReading(at: 12, direction: .backward)
    let firstForwardStepExpired = expiration.recordLinearReading(at: 13, direction: .forward)
    let secondForwardStepExpired = expiration.recordLinearReading(at: 14, direction: .forward)
    let thirdForwardStepExpired = expiration.recordLinearReading(at: 15, direction: .forward)
    let fourthForwardStepExpired = expiration.recordLinearReading(at: 16, direction: .forward)
    let fifthForwardStepExpired = expiration.recordLinearReading(at: 17, direction: .forward)

    #expect(!reversalExpired)
    #expect(!firstForwardStepExpired)
    #expect(!secondForwardStepExpired)
    #expect(!thirdForwardStepExpired)
    #expect(!fourthForwardStepExpired)
    #expect(fifthForwardStepExpired)
    #expect(!expiration.isArmed)
}

@Test func readerNavigationLinearReadingExpirationNeverExpiresWhileOscillatingDirection() {
    var expiration = ReaderNavigationLinearReadingExpiration<Int>(threshold: 3)

    expiration.arm(at: 10)

    var expired = false
    var pageKey = 10
    for step in 0..<10 {
        pageKey += step.isMultiple(of: 2) ? 1 : -1
        expired = expired || expiration.recordLinearReading(
            at: pageKey,
            direction: step.isMultiple(of: 2) ? .forward : .backward
        )
    }

    #expect(!expired)
    #expect(expiration.isArmed)
}

@Test func readerNavigationLinearReadingExpirationResetDisarmsTracking() {
    var expiration = ReaderNavigationLinearReadingExpiration<Int>(threshold: 2)

    expiration.arm(at: 1)
    let firstPageExpired = expiration.recordLinearReading(at: 2, direction: .forward)
    expiration.reset()
    let disarmedPageExpired = expiration.recordLinearReading(at: 3, direction: .forward)

    #expect(!firstPageExpired)
    #expect(!disarmedPageExpired)
    #expect(!expiration.isArmed)
}

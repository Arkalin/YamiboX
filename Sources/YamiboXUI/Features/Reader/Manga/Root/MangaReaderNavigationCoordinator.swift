import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class MangaReaderNavigationCoordinator {
    enum RestoreAttemptOutcome {
        case restored(prefetchIndex: Int)
        case aborted
        case failed
    }

    struct Reading {
        var stableReadingPosition: @MainActor () -> MangaReadingPosition?
        var restorePosition: @MainActor (MangaReadingPosition) async -> RestoreAttemptOutcome
        var scheduleAdjacentPrefetch: @MainActor (Int) -> Void
    }

    private let reading: Reading
    private var navigationHistory = ReaderNavigationHistory<MangaReadingPosition>()
    @ObservationIgnored private var linearReadingHistoryExpiration = ReaderNavigationLinearReadingExpiration<MangaReadingPosition>()
    @ObservationIgnored private var navigationRequestGeneration = 0

    init(reading: Reading) {
        self.reading = reading
    }

    var canNavigateBack: Bool {
        reading.stableReadingPosition() != nil && navigationHistory.canGoBack
    }

    var canNavigateForward: Bool {
        reading.stableReadingPosition() != nil && navigationHistory.canGoForward
    }

    func navigateBack() async {
        await restoreNavigationAnchor(direction: .back)
    }

    func navigateForward() async {
        await restoreNavigationAnchor(direction: .forward)
    }

    func beginNavigationRequest() -> Int {
        navigationRequestGeneration += 1
        return navigationRequestGeneration
    }

    func isCurrentNavigationRequest(_ generation: Int) -> Bool {
        navigationRequestGeneration == generation
    }

    func recordSuccessfulNonlinearNavigation(
        from sourcePosition: MangaReadingPosition?,
        to targetPosition: MangaReadingPosition
    ) {
        guard let sourcePosition, sourcePosition != targetPosition else { return }
        navigationHistory.recordNonlinearJump(from: sourcePosition, to: targetPosition)
        armLinearReadingHistoryExpirationIfNeeded()
    }

    func recordLinearReading(direction: ReaderNavigationLinearReadingDirection) {
        guard navigationHistory.canGoBack || navigationHistory.canGoForward else {
            linearReadingHistoryExpiration.reset()
            return
        }
        guard let position = reading.stableReadingPosition() else { return }
        if linearReadingHistoryExpiration.recordLinearReading(at: position, direction: direction) {
            navigationHistory.clear()
        }
    }

    func resetHistory() {
        invalidatePendingNavigation()
        navigationHistory = ReaderNavigationHistory()
        linearReadingHistoryExpiration.reset()
    }

    func invalidatePendingNavigation() {
        navigationRequestGeneration += 1
    }

    private enum NavigationRestoreDirection {
        case back
        case forward
    }

    private func restoreNavigationAnchor(direction: NavigationRestoreDirection) async {
        guard let sourcePosition = reading.stableReadingPosition() else { return }
        let navigationGeneration = beginNavigationRequest()

        while let targetPosition = navigationTarget(for: direction) {
            switch await reading.restorePosition(targetPosition) {
            case let .restored(prefetchIndex):
                guard isCurrentNavigationRequest(navigationGeneration) else { return }
                commitNavigationRestore(direction: direction, sourcePosition: sourcePosition)
                reading.scheduleAdjacentPrefetch(prefetchIndex)
                return
            case .aborted:
                return
            case .failed:
                guard isCurrentNavigationRequest(navigationGeneration) else { return }
                discardNavigationTarget(for: direction)
            }
        }
    }

    private func navigationTarget(for direction: NavigationRestoreDirection) -> MangaReadingPosition? {
        switch direction {
        case .back:
            navigationHistory.peekBack()
        case .forward:
            navigationHistory.peekForward()
        }
    }

    private func commitNavigationRestore(
        direction: NavigationRestoreDirection,
        sourcePosition: MangaReadingPosition
    ) {
        switch direction {
        case .back:
            navigationHistory.commitBack(from: sourcePosition)
        case .forward:
            navigationHistory.commitForward(from: sourcePosition)
        }
        armLinearReadingHistoryExpirationIfNeeded()
    }

    private func discardNavigationTarget(for direction: NavigationRestoreDirection) {
        switch direction {
        case .back:
            navigationHistory.discardBackCandidate()
        case .forward:
            navigationHistory.discardForwardCandidate()
        }
        resetLinearReadingHistoryExpirationIfHistoryIsEmpty()
    }

    private func armLinearReadingHistoryExpirationIfNeeded() {
        guard navigationHistory.canGoBack || navigationHistory.canGoForward,
              let position = reading.stableReadingPosition() else {
            linearReadingHistoryExpiration.reset()
            return
        }
        linearReadingHistoryExpiration.arm(at: position)
    }

    private func resetLinearReadingHistoryExpirationIfHistoryIsEmpty() {
        guard !navigationHistory.canGoBack, !navigationHistory.canGoForward else { return }
        linearReadingHistoryExpiration.reset()
    }
}

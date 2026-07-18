import Foundation
import YamiboXCore

/// Owns the manga reader's wayfinding across nonlinear jumps: the
/// back/forward navigation history, the request sequencing that lets a
/// newer jump invalidate an older one's history bookkeeping, and the
/// linear-reading expiration that clears stale anchors after enough
/// ordinary page turns. Counterpart of `NovelReaderNavigationCoordinator`,
/// with one deliberate shape difference: the history container itself
/// stays a tracked (observable) property on `MangaReaderViewModel` and is
/// reached through the `Reading` closures, because `MangaReaderView`
/// observes only the view model — hosting the state here would silently
/// stop the chrome's back/forward buttons from refreshing.
@MainActor
final class MangaReaderNavigationCoordinator {
    /// How a single restore attempt against reader content ended. The view
    /// model performs the actual jump (prefetch cancellation, content
    /// generations, presentation publishing are reader-content concerns);
    /// the coordinator only sequences attempts and history bookkeeping.
    enum RestoreAttemptOutcome {
        /// Content moved to the target; adjacent prefetch should resume
        /// around this global page index.
        case restored(prefetchIndex: Int)
        /// The whole restore request is void (no workflow, or the jump was
        /// cancelled) — stop without touching the remaining candidates.
        case aborted
        /// This target failed to load; discard it and try the next one.
        case failed
    }

    /// Reading context and load effects supplied by the owning view model.
    struct Reading {
        var navigationHistory: @MainActor () -> ReaderNavigationHistory<MangaReadingPosition>
        var setNavigationHistory: @MainActor (ReaderNavigationHistory<MangaReadingPosition>) -> Void
        var stableReadingPosition: @MainActor () -> MangaReadingPosition?
        var restorePosition: @MainActor (MangaReadingPosition) async -> RestoreAttemptOutcome
        var scheduleAdjacentPrefetch: @MainActor (Int) -> Void
    }

    private let reading: Reading
    private var linearReadingHistoryExpiration = ReaderNavigationLinearReadingExpiration<MangaReadingPosition>()
    private var navigationRequestGeneration = 0

    init(reading: Reading) {
        self.reading = reading
    }

    var canNavigateBack: Bool {
        reading.stableReadingPosition() != nil && reading.navigationHistory().canGoBack
    }

    var canNavigateForward: Bool {
        reading.stableReadingPosition() != nil && reading.navigationHistory().canGoForward
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
        var navigationHistory = reading.navigationHistory()
        navigationHistory.recordNonlinearJump(from: sourcePosition, to: targetPosition)
        reading.setNavigationHistory(navigationHistory)
        armLinearReadingHistoryExpirationIfNeeded()
    }

    func recordLinearReading(direction: ReaderNavigationLinearReadingDirection) {
        let navigationHistory = reading.navigationHistory()
        guard navigationHistory.canGoBack || navigationHistory.canGoForward else {
            linearReadingHistoryExpiration.reset()
            return
        }
        guard let position = reading.stableReadingPosition() else { return }
        if linearReadingHistoryExpiration.recordLinearReading(at: position, direction: direction) {
            var clearedHistory = navigationHistory
            clearedHistory.clear()
            reading.setNavigationHistory(clearedHistory)
        }
    }

    func resetHistory() {
        reading.setNavigationHistory(ReaderNavigationHistory())
        linearReadingHistoryExpiration.reset()
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
            reading.navigationHistory().peekBack()
        case .forward:
            reading.navigationHistory().peekForward()
        }
    }

    private func commitNavigationRestore(
        direction: NavigationRestoreDirection,
        sourcePosition: MangaReadingPosition
    ) {
        var navigationHistory = reading.navigationHistory()
        switch direction {
        case .back:
            navigationHistory.commitBack(from: sourcePosition)
        case .forward:
            navigationHistory.commitForward(from: sourcePosition)
        }
        reading.setNavigationHistory(navigationHistory)
        armLinearReadingHistoryExpirationIfNeeded()
    }

    private func discardNavigationTarget(for direction: NavigationRestoreDirection) {
        var navigationHistory = reading.navigationHistory()
        switch direction {
        case .back:
            navigationHistory.discardBackCandidate()
        case .forward:
            navigationHistory.discardForwardCandidate()
        }
        reading.setNavigationHistory(navigationHistory)
        resetLinearReadingHistoryExpirationIfHistoryIsEmpty()
    }

    private func armLinearReadingHistoryExpirationIfNeeded() {
        let navigationHistory = reading.navigationHistory()
        guard navigationHistory.canGoBack || navigationHistory.canGoForward,
              let position = reading.stableReadingPosition() else {
            linearReadingHistoryExpiration.reset()
            return
        }
        linearReadingHistoryExpiration.arm(at: position)
    }

    private func resetLinearReadingHistoryExpirationIfHistoryIsEmpty() {
        let navigationHistory = reading.navigationHistory()
        guard !navigationHistory.canGoBack, !navigationHistory.canGoForward else { return }
        linearReadingHistoryExpiration.reset()
    }
}

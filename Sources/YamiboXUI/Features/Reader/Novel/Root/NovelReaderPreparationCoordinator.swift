import Observation
import YamiboXCore

enum NovelReaderInitialPresentationPhase {
    case idle, preparing, waitingForLayout, layingOut, restoring, ready, failed, cancelled

    var concealsContent: Bool {
        switch self {
        case .idle, .preparing, .waitingForLayout, .layingOut, .restoring: true
        case .ready, .failed, .cancelled: false
        }
    }
}

/// Owns preparation task lifetime, stale-result admission and layout revisions.
/// The view model retains the workflow/data; only this coordinator changes the
/// initial presentation phase. Closing invalidates both kinds of pending work.
@MainActor
@Observable
final class NovelReaderPreparationCoordinator {
    enum PreparationRequest { case ignore, load, updateLayout }
    enum Step { case waitingForLayout, layingOut, restoring, failed, cancelled }

    private(set) var phase = NovelReaderInitialPresentationPhase.idle
    @ObservationIgnored private(set) var hasStarted = false
    @ObservationIgnored private(set) var layout = NovelReaderLayout.zero
    @ObservationIgnored private(set) var requestedLayout = NovelReaderLayout.zero
    @ObservationIgnored private(set) var layoutRevision: UInt64 = 0
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func prepare(layout: NovelReaderLayout) -> PreparationRequest {
        guard phase != .cancelled, phase != .failed else { return .ignore }
        if !hasStarted {
            hasStarted = true
            // Geometry can precede the view's appearance task.
            if requestedLayout == .zero {
                self.layout = layout
                requestedLayout = layout
                layoutRevision &+= 1
            }
        } else if phase == .ready {
            return .updateLayout
        }
        return .load
    }

    func runIfNeeded(_ operation: @escaping @MainActor (UInt64) async -> Void) async {
        guard phase != .cancelled, phase != .ready, phase != .restoring else { return }
        if let task {
            await task.value
            return
        }
        sequence &+= 1
        let token = sequence
        phase = .preparing
        let task = Task { [weak self] in
            await operation(token)
            if self?.isCurrent(token) == true { self?.task = nil }
        }
        self.task = task
        await task.value
        if isCurrent(token) { self.task = nil }
    }

    func isCurrent(_ token: UInt64) -> Bool { sequence == token }

    /// Release admission in the operation's defer, before its async caller
    /// resumes, so a new geometry callback can start a fresh waiting-layout run.
    func finishCurrentRun(_ token: UInt64) {
        if isCurrent(token) { task = nil }
    }

    func advance(to step: Step, for token: UInt64) {
        guard isCurrent(token), phase != .cancelled else { return }
        switch step {
        case .waitingForLayout: phase = .waitingForLayout
        case .layingOut: phase = .layingOut
        case .restoring: phase = .restoring
        case .failed: phase = .failed
        case .cancelled: phase = .cancelled
        }
    }

    func completeRestoration(hasPresentation: Bool, isRestoringViewport: Bool) {
        guard phase == .restoring, hasPresentation, !isRestoringViewport else { return }
        phase = .ready
    }

    func invalidateRestorationForLayoutChange() {
        if phase == .restoring { phase = .waitingForLayout }
    }

    @discardableResult
    func requestLayout(_ layout: NovelReaderLayout) -> UInt64 {
        if requestedLayout != layout {
            requestedLayout = layout
            layoutRevision &+= 1
        }
        return layoutRevision
    }

    func commitLayout(_ layout: NovelReaderLayout) {
        self.layout = layout
    }

    func rollbackLayoutRequest(ifCurrent revision: UInt64) {
        if layoutRevision == revision { requestedLayout = layout }
    }

    /// Await cancellation before the caller replaces the prepared data/workflow.
    func invalidateForRefresh() async -> Bool {
        sequence &+= 1
        let token = sequence
        let previousTask = task
        previousTask?.cancel()
        await previousTask?.value
        guard isCurrent(token), phase != .cancelled else { return false }
        task = nil
        return true
    }

    func close() {
        sequence &+= 1
        task?.cancel()
        task = nil
        phase = .cancelled
        layoutRevision &+= 1
        requestedLayout = layout
    }
}

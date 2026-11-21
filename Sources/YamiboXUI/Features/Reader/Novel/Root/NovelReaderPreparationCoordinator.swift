import Foundation
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

@MainActor
@Observable
final class NovelReaderPreparationCoordinator {
    enum PreparationRequest { case ignore, load, updateLayout }
    enum Step { case waitingForLayout, layingOut, restoring, failed, cancelled }

    private(set) var phase = NovelReaderInitialPresentationPhase.idle
    @ObservationIgnored private(set) var hasStarted = false
    private(set) var layout = NovelReaderLayout.zero
    @ObservationIgnored private(set) var requestedLayout = NovelReaderLayout.zero
    @ObservationIgnored private(set) var layoutRevision: UInt64 = 0
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var hasDisplayReporter = false
    @ObservationIgnored private var hasDisplayedInitialSurface = false
    @ObservationIgnored private var displayWaiter: (id: UUID, continuation: CheckedContinuation<Void, any Error>)?

    func setDisplayReporter(active: Bool) {
        hasDisplayReporter = active
        if !active {
            finishDisplayWait()
            hasDisplayedInitialSurface = false
        }
    }

    func initialSurfaceDidDisplay() {
        guard hasDisplayReporter, phase != .cancelled else { return }
        hasDisplayedInitialSurface = true
        finishDisplayWait()
    }

    func waitForInitialDisplay() async throws {
        guard hasDisplayReporter, !hasDisplayedInitialSurface else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled, phase != .cancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                displayWaiter = (id, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.displayWaiter?.id == id else { return }
                self?.finishDisplayWait(error: CancellationError())
            }
        }
    }

    private func finishDisplayWait(error: (any Error)? = nil) {
        let waiter = displayWaiter
        displayWaiter = nil
        if let error {
            waiter?.continuation.resume(throwing: error)
        } else {
            waiter?.continuation.resume()
        }
    }

    func prepare(layout: NovelReaderLayout) -> PreparationRequest {
        guard phase != .cancelled, phase != .failed else { return .ignore }
        if !hasStarted {
            hasStarted = true
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

    func resetForViewportChange(hasPresentation: Bool) {
        guard phase != .ready else { return }
        sequence &+= 1
        task?.cancel()
        task = nil
        finishDisplayWait(error: CancellationError())
        layoutRevision &+= 1
        if hasPresentation {
            requestedLayout = layout
            phase = .ready
        } else {
            hasStarted = false
            requestedLayout = .zero
            layout = .zero
            phase = .idle
        }
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
        finishDisplayWait(error: CancellationError())
        layoutRevision &+= 1
        requestedLayout = layout
    }
}

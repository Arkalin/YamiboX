import Foundation

package enum AppRuntimePhase: Sendable {
    case active
    case inactive
    case background
}

/// Owns app-lifetime subscriptions, not the lifetimes of the views showing them.
@MainActor
package final class AppRuntimeCoordinator {
    struct StoreObservation {
        let changeID: String
        let changes: @MainActor @Sendable () -> AsyncStream<String>
        let onChange: @MainActor @Sendable () -> Void
    }

    typealias ObservationOperation = @MainActor @Sendable () async -> Void

    struct Actions {
        var synchronizeForeground: @MainActor @Sendable () -> Void
        var refreshUnread: @MainActor @Sendable () async -> Void
        var invalidateUnread: @MainActor @Sendable () -> Void
        var synchronizeBackground: @MainActor @Sendable () -> Void
    }

    private let observations: [StoreObservation]
    private let operations: [ObservationOperation]
    private let actions: Actions
    private var observationTasks: [Task<Void, Never>] = []
    private var foregroundTask: Task<Void, Never>?
    private var runID: UUID?
    private var phaseID = UUID()
    private var phase: AppRuntimePhase?

    init(observations: [StoreObservation], operations: [ObservationOperation], actions: Actions) {
        self.observations = observations
        self.operations = operations
        self.actions = actions
    }

    isolated deinit {
        stop()
    }

    package func start() {
        guard runID == nil else { return }
        let id = UUID()
        runID = id

        // Register before returning, so writes need not wait for task scheduling.
        for observation in observations {
            let stream = observation.changes()
            observationTasks.append(Task { [weak self] in
                for await incoming in stream {
                    guard !Task.isCancelled, self?.runID == id else { return }
                    guard incoming == observation.changeID else { continue }
                    observation.onChange()
                }
            })
        }
        for operation in operations {
            observationTasks.append(Task { [weak self] in
                guard !Task.isCancelled, self?.runID == id else { return }
                await operation()
            })
        }
    }

    /// Does not flush or undo work already handed to the continuity workflow.
    package func stop() {
        guard runID != nil else { return }
        runID = nil
        phase = nil
        phaseID = UUID()
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
        foregroundTask?.cancel()
        foregroundTask = nil
        actions.invalidateUnread()
    }

    /// Returns true only for a new phase in a running runtime, including the
    /// initial phase. The UI adapter uses this receipt for platform side effects.
    @discardableResult
    package func transition(to nextPhase: AppRuntimePhase) -> Bool {
        guard let runID, phase != nextPhase else { return false }
        phase = nextPhase
        let id = UUID()
        phaseID = id
        switch nextPhase {
        case .active:
            foregroundTask?.cancel()
            actions.synchronizeForeground()
            let refreshUnread = actions.refreshUnread
            foregroundTask = Task { [weak self] in
                guard !Task.isCancelled, self?.runID == runID, self?.phaseID == id else { return }
                await refreshUnread()
                if self?.phaseID == id { self?.foregroundTask = nil }
            }
        case .background:
            foregroundTask?.cancel()
            foregroundTask = nil
            actions.invalidateUnread()
            actions.synchronizeBackground()
        case .inactive:
            break
        }
        return true
    }
}

import Foundation

/// Owns session task lifetimes and result admission. Content/navigation policy
/// remains in the workflow and its feature coordinators.
@MainActor
final class MangaReaderLifecycleCoordinator {
    enum Phase { case idle, preparing, ready, failed, resetting, closed }
    enum TaskKind: Hashable {
        case preparation, chapterJump, adjacentPrefetch, directoryObservation, bookmarkObservation, bookmarkRefresh, annotationRefresh
    }

    struct Request: Equatable {
        fileprivate let session: UUID
        fileprivate let kind: TaskKind
        fileprivate let id: UUID
    }

    struct ContentRevision: Equatable {
        fileprivate let session: UUID
        fileprivate let id: UUID
    }

    private struct RunningTask {
        let request: Request
        let task: Task<Void, Never>
    }

    private(set) var phase = Phase.idle
    private var session = UUID()
    private var contentID = UUID()
    private var tasks: [TaskKind: RunningTask] = [:]
    private var retiringTasks: [UUID: Task<Void, Never>] = [:]
    private var adjacentNavigations: Set<UUID> = []
    private let onInvalidate: @MainActor () -> Void

    init(onInvalidate: @escaping @MainActor () -> Void) {
        self.onInvalidate = onInvalidate
    }

    isolated deinit {
        for running in tasks.values { running.task.cancel() }
        for task in retiringTasks.values { task.cancel() }
    }

    var isClosed: Bool { phase == .closed }
    var acceptsResults: Bool { phase != .closed && phase != .resetting }
    var contentRevision: ContentRevision { ContentRevision(session: session, id: contentID) }
    var hasAdjacentNavigation: Bool { !adjacentNavigations.isEmpty }

    func isRunning(_ kind: TaskKind) -> Bool { tasks[kind] != nil }

    func accepts(_ request: Request) -> Bool {
        !Task.isCancelled && acceptsResults && request.session == session && tasks[request.kind]?.request == request
    }

    func accepts(_ revision: ContentRevision) -> Bool {
        !Task.isCancelled && acceptsResults && revision == contentRevision
    }

    @discardableResult
    func start(_ kind: TaskKind, operation: @escaping @MainActor (Request) async -> Void) -> Task<Void, Never>? {
        guard phase != .closed, phase != .resetting else { return nil }
        retire(kind)
        let request = Request(session: session, kind: kind, id: UUID())
        let task = Task { [weak self] in
            defer { self?.finish(request) }
            guard self?.accepts(request) == true else { return }
            await operation(request)
        }
        tasks[kind] = RunningTask(request: request, task: task)
        return task
    }

    func prepare(_ operation: @escaping @MainActor (Request) async -> Bool) async {
        guard phase == .idle else { return }
        phase = .preparing
        guard let task = start(.preparation, operation: { [weak self] request in
            let succeeded = await operation(request)
            guard let self, tasks[.preparation]?.request == request, session == request.session else { return }
            phase = succeeded && !Task.isCancelled ? .ready : .failed
        }) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// A retry cannot replace workflow data while an old preparation is alive.
    func resetForRetry() async -> Bool {
        guard phase != .closed, phase != .resetting else { return false }
        phase = .resetting
        let retiring = invalidateSession()
        let resetSession = session
        for task in retiring { await task.value }
        guard phase != .closed, session == resetSession else { return false }
        phase = .idle
        return !Task.isCancelled
    }

    func close() {
        guard !isClosed else { return }
        phase = .closed
        _ = invalidateSession()
    }

    func invalidateContent() {
        contentID = UUID()
        // Chapter-load admission belongs to MangaReaderWorkflow. Retiring it
        // here would also cancel a navigation that can safely rebase across a
        // directory-only commit.
        retire(.adjacentPrefetch)
    }

    func beginAdjacentNavigation() -> UUID {
        let id = UUID()
        adjacentNavigations.insert(id)
        invalidateContent()
        return id
    }

    func finishAdjacentNavigation(_ id: UUID) {
        adjacentNavigations.remove(id)
    }

    private func invalidateSession() -> [Task<Void, Never>] {
        session = UUID()
        contentID = UUID()
        for running in tasks.values { retiringTasks[running.request.id] = running.task }
        let retiring = Array(retiringTasks.values)
        tasks.removeAll()
        adjacentNavigations.removeAll()
        retiring.forEach { $0.cancel() }
        onInvalidate()
        return retiring
    }

    private func retire(_ kind: TaskKind) {
        guard let running = tasks.removeValue(forKey: kind) else { return }
        retiringTasks[running.request.id] = running.task
        running.task.cancel()
    }

    private func finish(_ request: Request) {
        if tasks[request.kind]?.request == request {
            if request.kind == .preparation, phase == .preparing { phase = .failed }
            tasks[request.kind] = nil
        }
        retiringTasks[request.id] = nil
    }
}

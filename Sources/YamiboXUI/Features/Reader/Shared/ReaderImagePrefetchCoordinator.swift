import Foundation
import YamiboXCore

@MainActor
final class ReaderImagePrefetchCoordinator {
    private struct Request {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let isCached: @MainActor (YamiboImageSource) -> Bool
    private let load: @MainActor (YamiboImageSource) async throws -> Void
    private var sources: [YamiboImageSource] = []
    private var attemptedKeys = Set<String>()
    private var requests: [String: Request] = [:]
    private static let maximumConcurrentRequests = 2

    convenience init(pipeline: YamiboUIImagePipeline) {
        self.init(
            isCached: { pipeline.cachedImage(for: $0) != nil },
            load: { _ = try await pipeline.image(for: $0, priority: .low) }
        )
    }

    init(
        isCached: @escaping @MainActor (YamiboImageSource) -> Bool,
        load: @escaping @MainActor (YamiboImageSource) async throws -> Void
    ) {
        self.isCached = isCached
        self.load = load
    }

    deinit {
        for request in requests.values {
            request.task.cancel()
        }
    }

    func update(sources: [YamiboImageSource]) {
        var keys = Set<String>()
        self.sources = sources.filter { keys.insert($0.cacheKey).inserted }
        attemptedKeys.formIntersection(keys)
        for key in Array(requests.keys) where !keys.contains(key) {
            requests.removeValue(forKey: key)?.task.cancel()
        }
        startPendingRequests()
    }

    func cancel() {
        sources = []
        attemptedKeys.removeAll()
        for request in requests.values {
            request.task.cancel()
        }
        requests.removeAll()
    }

    private func startPendingRequests() {
        for source in sources {
            guard requests.count < Self.maximumConcurrentRequests else { return }
            let key = source.cacheKey
            guard !attemptedKeys.contains(key) else { continue }
            attemptedKeys.insert(key)
            guard !isCached(source) else { continue }
            let id = UUID()
            let load = self.load
            let task = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    try await load(source)
                } catch {
                    // Display loads retry independently; prefetch never interrupts reading.
                }
                self?.didFinish(key: key, id: id)
            }
            requests[key] = Request(id: id, task: task)
        }
    }

    private func didFinish(key: String, id: UUID) {
        // A cancelled request can finish after this URL has re-entered the window.
        guard requests[key]?.id == id else { return }
        requests.removeValue(forKey: key)
        startPendingRequests()
    }
}

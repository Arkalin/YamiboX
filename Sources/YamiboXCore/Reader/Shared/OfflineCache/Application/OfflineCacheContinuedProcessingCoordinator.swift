import Foundation

#if os(iOS) && canImport(BackgroundTasks)
@preconcurrency import BackgroundTasks
#endif

public final class OfflineCacheContinuedProcessingCoordinator: OfflineCacheQueueRunObserving, @unchecked Sendable {
    public static let permittedIdentifier = "com.arkalin.YamiboX.offlineCache.continuedProcessing.*"

    private let lock = NSLock()
    private let title: String
    private let subtitle: String
    private var activeTaskCompletion: (@Sendable (Bool) -> Void)?
    private var activeProgress: Progress?
    #if os(iOS) && canImport(BackgroundTasks)
    private var launchHandler: LaunchHandler?
    #endif

    public init(
        title: String = L10n.string("mine.download_queue"),
        subtitle: String = L10n.string("mine.offline_queue.preparing")
    ) {
        self.title = title
        self.subtitle = subtitle
    }

    public func submitUserInitiatedRun() async {
        #if os(iOS) && canImport(BackgroundTasks)
        guard #available(iOS 26.0, *) else { return }
        let identifier = Self.makeTaskIdentifier()
        guard registerLaunchHandler(for: identifier) else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .queue
        request.requiredResources = []
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            YamiboLog.offlineCache.warning("Failed to submit background continued-processing task request for offline cache queue: \(error)")
            return
        }
        #endif
    }

    public func queueRunDidUpdateProgress(
        completedImageCount: Int,
        targetImageCount: Int
    ) async {
        let progress = lock.withLock { activeProgress }
        guard let progress else { return }

        progress.totalUnitCount = max(Int64(targetImageCount), 1)
        progress.completedUnitCount = min(
            max(Int64(completedImageCount), 0),
            progress.totalUnitCount
        )
    }

    public func queueRunDidFinish(success: Bool) async {
        let completion = lock.withLock {
            let completion = activeTaskCompletion
            activeTaskCompletion = nil
            activeProgress = nil
            return completion
        }
        completion?(success)
    }

    public func queueRunDidCancel() async {
        await queueRunDidFinish(success: false)
    }

    #if os(iOS) && canImport(BackgroundTasks)
    private struct LaunchHandler: Sendable {
        var queue: DispatchQueue?
        var continueQueue: @Sendable () async -> Void
        var pauseQueue: @Sendable () async -> Void
    }

    @available(iOS 26.0, *)
    public static func configureLaunchHandler(
        coordinator: OfflineCacheContinuedProcessingCoordinator,
        queue: DispatchQueue? = nil,
        continueQueue: @escaping @Sendable () async -> Void,
        pauseQueue: @escaping @Sendable () async -> Void
    ) {
        coordinator.configureLaunchHandler(
            queue: queue,
            continueQueue: continueQueue,
            pauseQueue: pauseQueue
        )
    }

    @available(iOS 26.0, *)
    public static func registerLaunchHandler(
        coordinator: OfflineCacheContinuedProcessingCoordinator,
        queue: DispatchQueue? = nil,
        continueQueue: @escaping @Sendable () async -> Void,
        pauseQueue: @escaping @Sendable () async -> Void
    ) {
        configureLaunchHandler(
            coordinator: coordinator,
            queue: queue,
            continueQueue: continueQueue,
            pauseQueue: pauseQueue
        )
    }

    @available(iOS 26.0, *)
    private func configureLaunchHandler(
        queue: DispatchQueue?,
        continueQueue: @escaping @Sendable () async -> Void,
        pauseQueue: @escaping @Sendable () async -> Void
    ) {
        lock.withLock {
            launchHandler = LaunchHandler(
                queue: queue,
                continueQueue: continueQueue,
                pauseQueue: pauseQueue
            )
        }
    }

    @available(iOS 26.0, *)
    private func registerLaunchHandler(for identifier: String) -> Bool {
        guard let launchHandler = lock.withLock({ launchHandler }) else { return false }

        return BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: launchHandler.queue
        ) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.attach(
                task: task,
                pauseQueue: launchHandler.pauseQueue
            )
            Task {
                await launchHandler.continueQueue()
            }
        }
    }

    @available(iOS 26.0, *)
    private func attach(
        task: BGContinuedProcessingTask,
        pauseQueue: @escaping @Sendable () async -> Void
    ) {
        lock.withLock {
            activeProgress = task.progress
            activeProgress?.totalUnitCount = 1
            activeProgress?.completedUnitCount = 0
            activeTaskCompletion = { success in
                task.setTaskCompleted(success: success)
            }
        }
        task.expirationHandler = {
            Task {
                await pauseQueue()
            }
        }
    }

    @available(iOS 26.0, *)
    private static func makeTaskIdentifier() -> String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.arkalin.YamiboX"
        return "\(bundleIdentifier).offlineCache.continuedProcessing.\(UUID().uuidString)"
    }
    #endif
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

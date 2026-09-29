import Foundation
import YamiboXCore

#if os(iOS) && canImport(BackgroundTasks)
@preconcurrency import BackgroundTasks
import UIKit
#endif

/// All scheduler state and system UI updates share the main actor. The core
/// queue runs independently even while the scheduler defers or rejects a request.
@MainActor
public final class DownloadContinuedProcessingCoordinator: DownloadQueueRunObserving {
    private static let taskIdentifierSuffix = "download.continuedProcessing"

    /// Run before exposing the download UI. A previous process's request has no
    /// surviving executor and must not be allowed to restart restored work.
    public static func cancelRestoredRequests() async {
        #if os(iOS) && canImport(BackgroundTasks)
        let legacyPrefix = "\(bundleIdentifier).offlineCache.continuedProcessing."
        let currentPrefix = "\(bundleIdentifier).\(taskIdentifierSuffix)."
        for request in await BGTaskScheduler.shared.pendingTaskRequests()
        where request.identifier.hasPrefix(legacyPrefix) || request.identifier.hasPrefix(currentPrefix) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request.identifier)
        }
        #endif
    }

    public static var permittedIdentifier: String {
        "\(bundleIdentifier).\(taskIdentifierSuffix).*"
    }

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.arkalin.YamiboX"
    }

    private struct Run {
        let id: DownloadRunID
        let identifier: String
        let pause: @Sendable () async -> Void
        var progress: DownloadQueueRunProgress
        var complete: ((Bool, DownloadQueueRunProgress) -> Void)?
        var publish: ((DownloadQueueRunProgress) -> Void)?
        var lastPublishedAt: ContinuousClock.Instant?
        var lastPhase: DownloadWorkPhase?
        var lastTitle: String?
        var pendingUpdate: Task<Void, Never>?
    }

    private var run: Run?
    // Finishes can race an actor hop made by a just-created worker.
    private var endedRuns: Set<DownloadRunID> = []

    public init() {}

    public func queueRunDidStart(
        id: DownloadRunID,
        progress: DownloadQueueRunProgress,
        pause: @escaping @Sendable () async -> Void
    ) async {
        guard !endedRuns.contains(id), run?.id != id else { return }
        #if os(iOS) && canImport(BackgroundTasks)
        guard #available(iOS 26.0, *),
              UIApplication.shared.applicationState == .active else { return }
        if let previous = run { finish(id: previous.id, success: false) }
        let identifier = "\(Self.bundleIdentifier).\(Self.taskIdentifierSuffix).\(id.rawValue.uuidString)"
        run = Run(id: id, identifier: identifier, pause: pause, progress: progress)
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { [weak self] task in
            // BGTaskScheduler explicitly dispatches this handler on .main.
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task, id: id)
            }
        }
        guard registered else {
            YamiboLog.download.error("Could not register continued download task")
            finish(id: id, success: false)
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: L10n.string("downloads.background.title"),
            subtitle: Self.subtitle(progress)
        )
        request.strategy = .queue
        request.requiredResources = []
        do {
            try BGTaskScheduler.shared.submit(request)
            YamiboLog.download.info("Submitted continued download run \(id.rawValue)")
        } catch {
            YamiboLog.download.warning("Continued download unavailable; keeping ordinary downloads: \(error)")
            finish(id: id, success: false)
        }
        #endif
    }

    public func queueRunDidUpdateProgress(id: DownloadRunID, progress: DownloadQueueRunProgress) async {
        guard run?.id == id else { return }
        run?.progress = progress
        publish(id: id)
    }

    public func queueRunDidFinish(id: DownloadRunID, success: Bool) async {
        finish(id: id, success: success)
    }

    private func finish(id: DownloadRunID, success: Bool) {
        endedRuns.insert(id)
        guard let current = run, current.id == id else { return }
        run = nil
        current.pendingUpdate?.cancel()
        #if os(iOS) && canImport(BackgroundTasks)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: current.identifier)
        #endif
        current.complete?(success, current.progress)
        YamiboLog.download.info("Ended continued download run \(id.rawValue), success: \(success)")
    }

    private func publish(id: DownloadRunID, force: Bool = false) {
        guard let current = run, current.id == id, let publish = current.publish else { return }
        let now = ContinuousClock.now
        let stageChanged = current.lastPhase != current.progress.phase || current.lastTitle != current.progress.currentTitle
        if !force, !stageChanged, let last = current.lastPublishedAt, now - last < .seconds(1) {
            if current.pendingUpdate == nil {
                run?.pendingUpdate = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(1) - (now - last)) }
                    catch { return }
                    guard self?.run?.id == id else { return }
                    self?.run?.pendingUpdate = nil
                    self?.publish(id: id, force: true)
                }
            }
            return
        }
        run?.pendingUpdate?.cancel()
        run?.pendingUpdate = nil
        run?.lastPublishedAt = now
        run?.lastPhase = current.progress.phase
        run?.lastTitle = current.progress.currentTitle
        publish(current.progress)
    }

    private static func subtitle(_ progress: DownloadQueueRunProgress) -> String {
        let phase: String
        switch progress.phase {
        case .preparing: phase = L10n.string("downloads.background.preparing")
        case .transferring:
            if progress.hasUnknownLength {
                phase = L10n.string("downloads.background.received",
                    ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file))
            } else {
                phase = L10n.string("downloads.background.transferring")
            }
        case .saving: phase = L10n.string("downloads.background.saving")
        }
        return L10n.string("downloads.background.progress",
            progress.completedWorkCount, progress.totalWorkCount, progress.currentTitle, phase)
    }

    #if os(iOS) && canImport(BackgroundTasks)
    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask, id: DownloadRunID) {
        guard run?.id == id, run?.complete == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let current = self?.run, current.id == id else { return }
                // End system ownership promptly, then cancel only this run's work.
                self?.finish(id: id, success: false)
                await current.pause()
            }
        }
        run?.complete = { success, progress in
            task.expirationHandler = nil
            if success {
                task.updateTitle(
                    L10n.string("downloads.background.completed"),
                    subtitle: L10n.string("downloads.background.completed_count", progress.completedWorkCount)
                )
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            task.setTaskCompleted(success: success)
        }
        run?.publish = { progress in
            task.progress.totalUnitCount = Int64(max(1, progress.totalWorkCount)) * 10_000
            task.progress.completedUnitCount = min(
                task.progress.totalUnitCount - 1,
                Int64(progress.fractionCompleted * Double(task.progress.totalUnitCount))
            )
            task.updateTitle(L10n.string("downloads.background.title"), subtitle: Self.subtitle(progress))
        }
        publish(id: id, force: true)
    }
    #endif
}

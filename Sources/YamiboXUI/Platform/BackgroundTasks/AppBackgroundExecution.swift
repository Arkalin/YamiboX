import UIKit
import YamiboXCore

/// Acquire before starting the operation, including in the foreground, so an
/// in-flight sync is already protected when the app moves into the background.
@MainActor
final class AppBackgroundExecution: AppBackgroundExecutionProtecting {
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let lease = Lease()
        let task = Task {
            try Task.checkCancellation()
            return try await operation()
        }
        lease.identifier = UIApplication.shared.beginBackgroundTask(withName: "WebDAV sync") {
            task.cancel()
            lease.end()
        }
        guard lease.identifier != .invalid else {
            task.cancel()
            throw CancellationError()
        }
        defer { lease.end() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @MainActor
    private final class Lease {
        var identifier: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}

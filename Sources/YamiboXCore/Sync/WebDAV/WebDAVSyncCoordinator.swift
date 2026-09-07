import Foundation

/// Shared by every service using one settings store. Actor isolation alone
/// does not serialize operations across network suspension points.
actor WebDAVSyncCoordinator {
    private var tail: Task<Void, Never>?
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    private var isResetting = false
    private var verifiedConnection: WebDAVConnectionIdentity?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !isResetting else { throw CancellationError() }
        let predecessor = tail
        let id = UUID()
        let task = Task {
            await predecessor?.value
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }
        tail = Task { _ = try? await task.value }
        cancellations[id] = { task.cancel() }
        defer {
            cancellations[id] = nil
            if cancellations.isEmpty { tail = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func reset(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        guard !isResetting else { throw CancellationError() }
        isResetting = true
        defer { isResetting = false }
        for cancel in cancellations.values { cancel() }
        await tail?.value
        verifiedConnection = nil
        try await operation()
    }

    func hasVerified(_ connection: WebDAVConnectionIdentity) -> Bool {
        verifiedConnection == connection
    }

    func markVerified(_ connection: WebDAVConnectionIdentity) {
        verifiedConnection = connection
    }
}

struct WebDAVConnectionIdentity: Equatable, Sendable {
    let baseURL: String
    let username: String
    let password: String

    init(_ settings: WebDAVSyncSettings) {
        baseURL = settings.trimmedBaseURLString
        username = settings.trimmedUsername
        password = settings.password
    }
}

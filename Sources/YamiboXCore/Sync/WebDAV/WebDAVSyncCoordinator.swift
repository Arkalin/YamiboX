import Foundation

/// Shared by every service using one settings store. Actor isolation alone
/// does not serialize operations across network suspension points.
actor WebDAVSyncCoordinator {
    struct RunToken: Sendable {
        fileprivate let id: UUID
        fileprivate let epoch: UInt64
    }

    struct ConnectionChangeToken: Sendable {
        fileprivate let id: UUID
    }

    private var tail: Task<Void, Never>?
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    private var isResetting = false
    private var epoch: UInt64 = 0
    private var connectionChangeID: UUID?
    private var verifiedConnection: WebDAVConnectionIdentity?

    func run<T: Sendable>(_ operation: @escaping @Sendable (RunToken) async throws -> T) async throws -> T {
        guard !isResetting else { throw CancellationError() }
        let predecessor = tail
        let id = UUID()
        let token = RunToken(id: id, epoch: epoch)
        let task = Task {
            await predecessor?.value
            try Task.checkCancellation()
            try await self.checkCurrent(token)
            let result = try await operation(token)
            try Task.checkCancellation()
            try await self.checkCurrent(token)
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

    /// Cancels and joins every queued or active sync run, then holds the
    /// barrier while the caller publishes a new connection. The epoch is
    /// advanced before the barrier is released, so an operation that retained
    /// old settings cannot be admitted merely because it was queued earlier.
    func beginConnectionChange() async throws -> ConnectionChangeToken {
        guard !isResetting else { throw CancellationError() }
        try Task.checkCancellation()
        isResetting = true
        let token = ConnectionChangeToken(id: UUID())
        connectionChangeID = token.id
        for cancel in cancellations.values { cancel() }
        let tail = self.tail
        await tail?.value
        do {
            try Task.checkCancellation()
        } catch {
            connectionChangeID = nil
            isResetting = false
            throw error
        }
        epoch &+= 1
        verifiedConnection = nil
        return token
    }

    func endConnectionChange(_ token: ConnectionChangeToken) {
        guard connectionChangeID == token.id else { return }
        connectionChangeID = nil
        isResetting = false
    }

    func checkCurrent(_ token: RunToken) async throws {
        guard !isResetting, token.epoch == epoch else { throw CancellationError() }
    }

    func reset(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let token = try await beginConnectionChange()
        do {
            try await operation()
            endConnectionChange(token)
        } catch {
            endConnectionChange(token)
            throw error
        }
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

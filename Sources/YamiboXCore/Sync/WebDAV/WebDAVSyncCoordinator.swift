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
    private var cachedConnection: WebDAVConnectionIdentity?
    private var cachedReceiptScope: WebDAVReceiptScope?
    private var remoteFiles: [String: WebDAVRemoteFile] = [:]
    private var lastAutomaticReconciliation: Date?
    private static let maximumCachedBytes = 16 * 1024 * 1024

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
        cachedConnection = nil
        cachedReceiptScope = nil
        remoteFiles.removeAll()
        lastAutomaticReconciliation = nil
        return token
    }

    func endConnectionChange(_ token: ConnectionChangeToken) {
        guard connectionChangeID == token.id else { return }
        connectionChangeID = nil
        isResetting = false
    }

    func checkCurrent(_ token: RunToken) async throws {
        try Task.checkCancellation()
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

    /// In-memory bodies never cross connection/account boundaries or survive a
    /// reset. The coordinator is shared even when a caller creates a new service.
    private func prepareCacheScope(_ settings: WebDAVSyncSettings) {
        let connection = WebDAVConnectionIdentity(settings)
        guard cachedConnection != connection || cachedReceiptScope != settings.receiptScope else { return }
        cachedConnection = connection
        cachedReceiptScope = settings.receiptScope
        remoteFiles.removeAll()
        lastAutomaticReconciliation = nil
    }

    func cachedRemoteFile(_ name: String, settings: WebDAVSyncSettings) -> WebDAVRemoteFile? {
        prepareCacheScope(settings)
        return remoteFiles[name]
    }

    func cacheRemoteFile(_ file: WebDAVRemoteFile?, name: String, settings: WebDAVSyncSettings) {
        prepareCacheScope(settings)
        remoteFiles[name] = nil
        guard let file, let etag = file.etag, WebDAVClient.isStrongETag(etag),
              file.data.count <= Self.maximumCachedBytes else { return }
        if remoteFiles.values.reduce(0, { $0 + $1.data.count }) + file.data.count > Self.maximumCachedBytes {
            remoteFiles.removeAll()
        }
        remoteFiles[name] = file
    }

    func lastAutomaticReconciliation(settings: WebDAVSyncSettings) -> Date? {
        prepareCacheScope(settings)
        return lastAutomaticReconciliation
    }

    func recordAutomaticReconciliation(settings: WebDAVSyncSettings) {
        prepareCacheScope(settings)
        lastAutomaticReconciliation = .now
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

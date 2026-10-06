/// A short execution lease, not a scheduler or permission to run indefinitely.
/// The platform adapter cancels the operation when the system expires the lease.
public protocol AppBackgroundExecutionProtecting: Sendable {
    @MainActor
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T
}

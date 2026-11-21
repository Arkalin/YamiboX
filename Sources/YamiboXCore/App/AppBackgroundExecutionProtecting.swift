public protocol AppBackgroundExecutionProtecting: Sendable {
    @MainActor
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T
}

import Foundation

@MainActor
enum StoreChangeObservation {
    /// Starts a long-lived observation task. Cancel it (typically in
    /// `deinit`) to end the observation; capture `self` weakly in `onChange`.
    ///
    /// Register synchronously before returning, so a write before the task's
    /// first turn is buffered rather than lost. Store invalidations coalesce
    /// while `onChange` is running; the handler must reload current state, not
    /// interpret each signal as one individual mutation.
    static func task(
        changes: @escaping @Sendable () -> AsyncStream<Void>,
        onChange: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let stream = changes()
        return Task { @MainActor in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await onChange()
            }
        }
    }
}

import Foundation

/// The store-changed subscription every view model repeats: consume a
/// store's typed `changes()` stream, drop elements whose `changeID` doesn't
/// match the observed store instance, and run a handler per surviving
/// change. The stream is already per-instance, so the guard is normally a
/// tautology — it is kept as the explicit, self-documenting instance-match
/// contract, and it stays load-bearing for protocol-typed stores (e.g.
/// `MangaDirectoryPersisting` fakes) whose defaulted `changeID` must never
/// match anything.
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
        changes: @escaping @Sendable () -> AsyncStream<String>,
        changeID: @escaping @Sendable () -> String,
        onChange: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let stream = changes()
        return Task { @MainActor in
            for await incoming in stream {
                guard !Task.isCancelled else { return }
                guard incoming == changeID() else {
                    continue
                }
                await onChange()
            }
        }
    }
}

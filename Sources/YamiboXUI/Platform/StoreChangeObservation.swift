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
    /// `changes` is called inside the task body — not at `task(...)` time —
    /// so subscription starts exactly where the old
    /// `NotificationCenter.notifications(named:)` sequence used to be
    /// created, keeping the "changes posted before the task first runs are
    /// not delivered" timing unchanged.
    static func task(
        changes: @escaping @Sendable () -> AsyncStream<String>,
        changeID: @escaping @Sendable () -> String,
        onChange: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            for await incoming in changes() {
                guard !Task.isCancelled else { return }
                guard incoming == changeID() else {
                    continue
                }
                await onChange()
            }
        }
    }
}

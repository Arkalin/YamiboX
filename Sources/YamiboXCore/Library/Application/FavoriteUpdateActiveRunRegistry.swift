import Foundation

/// Shares one driving task per store instance. The change feed identity also
/// scopes injected stores without relying on reference casts of protocol values.
@MainActor
public final class FavoriteUpdateActiveRunRegistry {
    public static let shared = FavoriteUpdateActiveRunRegistry()

    final class Run {
        let storeID: String
        var snapshot: FavoriteUpdateRunSnapshot
        var preparation: Task<Bool, Never>?
        var driver: Task<Void, Never>?
        var interrupt: (() async -> Void)?

        init(storeID: String, snapshot: FavoriteUpdateRunSnapshot) {
            self.storeID = storeID
            self.snapshot = snapshot
        }
    }

    private var runs: [String: Run] = [:]
    private var transitionDepth: [String: Int] = [:]
    private struct Observer {
        let snapshot: (FavoriteUpdateRunSnapshot) -> Void
        let finished: (FavoriteUpdateRunSnapshot) -> Void
    }
    private var observers: [String: [UUID: Observer]] = [:]

    public init() {}

    public func isActive(_ runID: String) -> Bool {
        runs.values.contains { $0.snapshot.runID == runID }
    }

    func run(storeID: String) -> Run? { runs[storeID] }

    func begin(storeID: String, snapshot: FavoriteUpdateRunSnapshot) -> Run? {
        guard runs[storeID] == nil, transitionDepth[storeID] == nil else { return nil }
        let run = Run(storeID: storeID, snapshot: snapshot)
        runs[storeID] = run
        publish(snapshot, for: run)
        return run
    }

    func publish(_ snapshot: FavoriteUpdateRunSnapshot, for run: Run) {
        guard runs[run.storeID] === run else { return }
        run.snapshot = snapshot
        for observer in Array(observers[run.storeID]?.values ?? [:].values) { observer.snapshot(snapshot) }
    }

    func finish(_ run: Run) {
        guard runs[run.storeID] === run else { return }
        runs.removeValue(forKey: run.storeID)
        for observer in Array(observers[run.storeID]?.values ?? [:].values) { observer.finished(run.snapshot) }
        run.interrupt = nil
        // Clear task captures after completion. Engines may retain the receipt
        // to wait for this exact run after another run has already begun.
        run.preparation = nil
        run.driver = nil
    }

    func observe(
        storeID: String, observerID: UUID,
        onSnapshot: @escaping (FavoriteUpdateRunSnapshot) -> Void,
        onFinished: @escaping (FavoriteUpdateRunSnapshot) -> Void
    ) {
        observers[storeID, default: [:]][observerID] = Observer(snapshot: onSnapshot, finished: onFinished)
        if let run = runs[storeID] { onSnapshot(run.snapshot) }
    }

    func removeObserver(storeID: String, observerID: UUID) {
        observers[storeID]?.removeValue(forKey: observerID)
        if observers[storeID]?.isEmpty == true { observers.removeValue(forKey: storeID) }
    }

    /// Account transitions block new admission before cancelling and joining the
    /// current driver, so no old-account request can outlive the transition.
    public func prepareForAccountChange(storeID: String) async {
        transitionDepth[storeID, default: 0] += 1
        guard let run = runs[storeID] else { return }
        let driver = run.driver
        run.preparation?.cancel()
        driver?.cancel()
        await driver?.value
    }

    public func finishAccountChange(storeID: String) {
        guard let depth = transitionDepth[storeID] else { return }
        if depth > 1 { transitionDepth[storeID] = depth - 1 }
        else { transitionDepth.removeValue(forKey: storeID) }
    }
}

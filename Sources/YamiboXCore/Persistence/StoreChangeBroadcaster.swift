import Foundation

/// One shared implementation of the store change signal that every data
/// store forwards to, now delivered as a typed multicast
/// `AsyncStream<String>` instead of the retired stringly-named
/// `NotificationCenter` post: the stream keeps the dependency visible to the
/// compiler (an observer must hold the store it observes) and cannot drift
/// from its payload contract the way a userInfo dictionary could.
///
/// Each element is the `changeID` of the store instance that made the
/// change, so observers keep the existing loop-filtering protocol unchanged:
/// compare the incoming ID against the instance they hold and skip changes
/// that originated elsewhere. Streams are handed out per store *instance*,
/// which already scopes delivery the way the old `changeID` guards did (a
/// parallel test's sibling instance no longer even reaches an observer), but
/// call sites keep their guards as the explicit, self-documenting contract.
///
/// `AsyncStream` is single-consumer, while one store has many observers, so
/// `post()` uses the same bounded multicast kernel as offline-cache invalidations.
struct StoreChangeBroadcaster: Sendable {
    /// Fresh per broadcaster — and each store creates exactly one broadcaster
    /// per instance — preserving the "changeID identifies a store instance"
    /// semantics observers rely on.
    let changeID = UUID().uuidString

    private let subscriptions = StoreInvalidationBroadcaster<String>()

    /// A new stream per call, registered synchronously before returning.
    /// Signals invalidate the consumer's snapshot; they are not a mutation
    /// log. Keep at most one pending signal while it reloads current state.
    /// A write during a reload still schedules a subsequent refresh, without
    /// replaying an unbounded backlog of identical invalidations.
    func changes() -> AsyncStream<String> {
        subscriptions.stream()
    }

    func post() {
        subscriptions.post(changeID)
    }
}

/// Multicast invalidations, not an event log. Each consumer reloads current
/// state, so only one pending signal is needed, including during a reload.
/// All mutable state is lock-protected; callbacks run outside the lock.
final class StoreInvalidationBroadcaster<Signal: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Signal>.Continuation] = [:]

    func stream() -> AsyncStream<Signal> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    func post(_ signal: Signal) {
        // Snapshot under the lock, yield outside it: a consumer's
        // onTermination can fire (and want the lock) while the fan-out
        // is still running.
        let activeContinuations = lock.withLock {
            Array(continuations.values)
        }
        for continuation in activeContinuations {
            continuation.yield(signal)
        }
    }

    private func removeContinuation(id: UUID) {
        _ = lock.withLock {
            continuations.removeValue(forKey: id)
        }
    }
}

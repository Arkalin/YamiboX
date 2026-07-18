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
/// `post()` fans out through a lock-protected continuation registry — the
/// same multicast pattern as `OfflineCacheStore`'s
/// `OfflineCacheUpdateNotifier`, deliberately mirrored so the codebase has
/// exactly one shape for "many observers of one async store signal". The
/// stores' private `postChangeNotification()` helpers all forward here.
struct StoreChangeBroadcaster: Sendable {
    /// Fresh per broadcaster — and each store creates exactly one broadcaster
    /// per instance — preserving the "changeID identifies a store instance"
    /// semantics observers rely on.
    let changeID = UUID().uuidString

    private let subscriptions = Subscriptions()

    /// A new stream per call; every registered stream receives every
    /// subsequent `post()`. Registration happens synchronously inside this
    /// call and elements buffer until iteration (`AsyncStream`'s default
    /// unbounded policy), so a consumer that obtains its stream first can
    /// never miss a change posted before its first `await`.
    func changes() -> AsyncStream<String> {
        subscriptions.stream()
    }

    func post() {
        subscriptions.yield(changeID)
    }

    /// Lock-protected continuation registry, copied from
    /// `OfflineCacheUpdateNotifier` (see `OfflineCacheStore`): `onTermination`
    /// (consumer cancelled, or the stream dropped) unregisters, so abandoned
    /// observers never accumulate across e.g. repeated view appearances.
    private final class Subscriptions: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

        func stream() -> AsyncStream<String> {
            AsyncStream { continuation in
                let id = UUID()
                lock.withLock {
                    continuations[id] = continuation
                }
                continuation.onTermination = { [weak self] _ in
                    self?.removeContinuation(id: id)
                }
            }
        }

        func yield(_ changeID: String) {
            // Snapshot under the lock, yield outside it: a consumer's
            // onTermination can fire (and want the lock) while the fan-out
            // is still running.
            let activeContinuations = lock.withLock {
                Array(continuations.values)
            }
            for continuation in activeContinuations {
                continuation.yield(changeID)
            }
        }

        private func removeContinuation(id: UUID) {
            _ = lock.withLock {
                continuations.removeValue(forKey: id)
            }
        }
    }
}

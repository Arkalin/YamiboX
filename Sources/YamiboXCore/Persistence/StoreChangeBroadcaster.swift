import Foundation

struct StoreChangeBroadcaster: Sendable {
    let changeID = UUID().uuidString

    private let subscriptions = StoreInvalidationBroadcaster<String>()

    func changes() -> AsyncStream<String> {
        subscriptions.stream()
    }

    func post() {
        subscriptions.post(changeID)
    }
}

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

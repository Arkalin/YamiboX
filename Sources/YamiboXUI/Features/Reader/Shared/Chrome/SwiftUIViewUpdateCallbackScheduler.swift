import Foundation

final class SwiftUIViewUpdateCallbackScheduler: @unchecked Sendable {
    private var viewUpdateDepth = 0
    private var isFlushScheduled = false
    private var pendingCallbacks: [() -> Void] = []

    func performViewUpdate(_ body: () -> Void) {
        viewUpdateDepth += 1
        defer { viewUpdateDepth = max(viewUpdateDepth - 1, 0) }
        body()
    }

    func publish(_ callback: @escaping () -> Void) {
        guard viewUpdateDepth > 0 || isFlushScheduled else {
            callback()
            return
        }
        pendingCallbacks.append(callback)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        isFlushScheduled = false
        let callbacks = pendingCallbacks
        pendingCallbacks.removeAll()
        callbacks.forEach { $0() }
    }
}

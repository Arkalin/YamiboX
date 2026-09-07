import Foundation
import YamiboXCore

struct TransientFeedback: Identifiable, Hashable, Sendable {
    let id: UUID
    let message: String
    let details: LoadFailureDetails?
    let createdAt = ContinuousClock.now

    init(message: String, details: LoadFailureDetails? = nil, id: UUID = UUID()) {
        self.id = id
        self.message = message
        self.details = details
    }

    static func failure(_ message: String, details: LoadFailureDetails? = nil) -> Self {
        Self(message: message, details: details ?? LoadFailureDetails(message: message))
    }

    static func failure(_ error: any Error, message: String? = nil) -> Self? {
        guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return nil }
        return failure(message ?? error.localizedDescription, details: LoadFailureDetails(error: error))
    }

    static func latest(_ first: Self?, _ second: Self?) -> Self? {
        guard let first else { return second }
        guard let second else { return first }
        return first.createdAt > second.createdAt ? first : second
    }
}

/// Supplying monotonic time makes pause/resume testable without sleeping.
struct TransientFeedbackCountdown {
    private(set) var id: UUID?
    private(set) var remaining: Duration = .zero
    private(set) var startedAt: Duration?

    static func duration(for message: String, minimumSeconds: Double = 3) -> Duration {
        .seconds(min(max(minimumSeconds, Double(message.count) * 0.12), 8))
    }

    mutating func replace(id: UUID?, duration: Duration, now: Duration) {
        self.id = id
        remaining = duration
        startedAt = id == nil ? nil : now
    }

    mutating func pause(id: UUID, now: Duration) {
        guard self.id == id, let startedAt else { return }
        remaining = max(.zero, remaining - max(.zero, now - startedAt))
        self.startedAt = nil
    }

    mutating func resume(id: UUID, now: Duration) {
        guard self.id == id, startedAt == nil else { return }
        startedAt = now
    }

    func canExpire(id: UUID, now: Duration) -> Bool {
        guard self.id == id, let startedAt else { return false }
        return now - startedAt >= remaining
    }
}

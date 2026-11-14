import Foundation

/// A completed network operation must not be restarted by a feature's own
/// retry or browser fallback. Cached content remains usable unless cancelled.
public enum NetworkFailureRecovery: Sendable {
    case cancelled
    case exhausted

    public static func state(of error: any Error) -> Self? {
        if LoadDiagnosticError.isCancellation(error) { return .cancelled }
        guard let failure = LoadDiagnosticError.classificationError(error) as? ForumWAFFailure else { return nil }
        return failure == .sessionInvalidated ? .cancelled : .exhausted
    }
}

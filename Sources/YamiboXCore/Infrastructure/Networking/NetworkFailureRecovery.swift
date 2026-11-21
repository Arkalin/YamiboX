import Foundation

public enum NetworkFailureRecovery: Sendable {
    case cancelled
    case exhausted

    public static func state(of error: any Error) -> Self? {
        if LoadDiagnosticError.isCancellation(error) { return .cancelled }
        guard let failure = LoadDiagnosticError.classificationError(error) as? ForumWAFFailure else { return nil }
        return failure == .sessionInvalidated ? .cancelled : .exhausted
    }
}

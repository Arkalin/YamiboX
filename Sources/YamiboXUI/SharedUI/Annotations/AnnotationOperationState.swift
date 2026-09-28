import Observation
import SwiftUI
import YamiboXCore

/// Presentation-only failure handling shared by reader and Like surfaces.
@MainActor
@Observable
final class AnnotationOperationState {
    var failure: LoadFailureDetails?

    func report(_ error: any Error) {
        guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
        failure = LoadFailureDetails(error: error)
    }

    @discardableResult
    func perform<Value>(_ operation: @MainActor () async throws -> Value) async -> Value? {
        do { return try await operation() }
        catch {
            report(error)
            return nil
        }
    }
}

extension View {
    func annotationOperationFeedback(_ state: AnnotationOperationState) -> some View {
        failureToast(message: state.failure?.summary, details: state.failure) {
            state.failure = nil
        }
    }
}

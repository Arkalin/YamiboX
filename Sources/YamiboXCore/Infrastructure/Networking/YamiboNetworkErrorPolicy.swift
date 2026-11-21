import Foundation

enum YamiboNetworkErrorPolicy {
    static func isOffline(_ error: any Error) -> Bool {
        let source = LoadDiagnosticError.classificationError(error)
        if let yamiboError = source as? YamiboError, case .offline = yamiboError {
            return true
        }
        guard let urlError = source as? URLError else { return false }
        return urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost
    }

    static func mappingErrors<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch {
            let source = LoadDiagnosticError.classificationError(error)
            guard source is URLError, !LoadDiagnosticError.isCancellation(error) else { throw error }
            let recoveryError: YamiboError = isOffline(source)
                ? .offline
                : .underlying(error.localizedDescription)
            throw LoadDiagnosticError.mapping(error, to: recoveryError)
        }
    }
}

import Foundation

/// Bounded retries for read-only sync requests; failures leave their original
/// diagnostic wrapper intact for the engine's item/run failure decision.
struct FavoriteRemoteSyncRetryPolicy: Sendable {
    var wait: @Sendable (_ retry: Int) async throws -> Void = { retry in
        try await Task.sleep(for: .milliseconds(250 * retry))
    }

    func run<Value>(attempts: Int = 3, operation: () async throws -> Value) async throws -> Value {
        let attempts = max(1, attempts)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                try Task.checkCancellation()
                guard !LoadDiagnosticError.isCancellation(error),
                      !Self.isRunFatal(error),
                      Self.isRetryable(error),
                      attempt < attempts else {
                    throw error
                }
                try await wait(attempt)
                attempt += 1
            }
        }
    }

    static func isRunFatal(_ error: any Error) -> Bool {
        let source = LoadDiagnosticError.classificationError(error)
        if let favoriteError = source as? FavoriteActionError {
            return favoriteError == .missingFavoriteAddToken
        }
        if let urlError = source as? URLError {
            return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(urlError.code)
        }
        guard let yamiboError = source as? YamiboError else { return false }
        switch yamiboError {
        case .notAuthenticated, .floodControl, .securityVerificationRequired, .offline:
            return true
        default:
            return false
        }
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        let source = LoadDiagnosticError.classificationError(error)
        if let urlError = source as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code)
        }
        guard let yamiboError = source as? YamiboError else { return false }
        switch yamiboError {
        case let .invalidResponse(statusCode):
            return statusCode == nil || statusCode == 408 || statusCode.map { 500...599 ~= $0 } == true
        case .parsingFailed, .emptyHTML, .unreadableBody:
            // A transient incomplete page can fail parsing; retain the
            // existing bounded retry rather than importing a placeholder.
            return true
        default:
            return false
        }
    }
}

import Foundation

/// Adapters throw this only after the shared classifier has isolated a challenge.
struct ForumTransportChallenge: Error, Sendable {
    let challenge: YamiboWAFChallenge
}

public struct ForumRequestExecutor: ForumRequestExecuting {
    public static let unavailable = Self(recovery: ForumWAFRecoveryCoordinator(verifier: UnavailableForumSilentVerifier()))
    private let recovery: ForumWAFRecoveryCoordinator

    public init(recovery: ForumWAFRecoveryCoordinator) {
        self.recovery = recovery
    }

    /// The WebKit adapter has already made its first navigation. Reuse the
    /// same execution contract for its observed challenge, without giving the
    /// verifier any navigation or presentation authority.
    public func recoverNavigation(context: ForumRequestContext, policy: ForumRequestPolicy,
                                  challenge: YamiboWAFChallenge) async throws -> YamiboRequestCredentials {
        try await execute(context: context, policy: policy) { attempt in
            if attempt.number == 1 { throw ForumTransportChallenge(challenge: challenge) }
            return attempt.credentials
        }
    }

    public func execute<Value: Sendable>(
        context: ForumRequestContext,
        policy: ForumRequestPolicy,
        transport: @escaping @Sendable (ForumRequestAttempt) async throws -> Value
    ) async throws -> Value {
        let operationID = policy.operation.id
        do {
            let result = try await perform(context: context, policy: policy, transport: transport)
            YamiboLog.networking.info("Forum operation=\(operationID, privacy: .public) terminal=success")
            return result
        } catch {
            let failure = LoadDiagnosticError.classificationError(error)
            let terminal = (failure as? ForumWAFFailure)?.rawValue
                ?? (failure is CancellationError || (failure as? URLError)?.code == .cancelled ? "cancelled" : "transportFailure")
            YamiboLog.networking.info("Forum operation=\(operationID, privacy: .public) terminal=\(terminal, privacy: .public)")
            throw error
        }
    }

    private func perform<Value: Sendable>(
        context: ForumRequestContext,
        policy: ForumRequestPolicy,
        transport: @escaping @Sendable (ForumRequestAttempt) async throws -> Value
    ) async throws -> Value {
        let operationID = policy.operation.id
        try Task.checkCancellation()
        try await context.validate()
        guard policy.lease.isValid else { throw ForumWAFFailure.runtimeUnavailable }
        let number = try policy.operation.reserveAttempt(replay: policy.replay)
        YamiboLog.networking.info("Forum operation=\(operationID, privacy: .public) scope=\(context.key.scopeID, privacy: .public) generation=\(context.key.generation, privacy: .public) attempt=\(number, privacy: .public) start")
        let first = ForumRequestAttempt(operationID: operationID, number: number, context: context,
                                        credentials: context.credentials, lease: policy.lease)
        do {
            let result = try await transport(first)
            try await context.validate()
            if number != 1 || !policy.deliversCompletedInitialResponse { try Task.checkCancellation() }
            YamiboLog.networking.info("Forum operation=\(operationID, privacy: .public) attempt=\(number, privacy: .public) success")
            return result
        } catch let blocked as ForumTransportChallenge {
            YamiboLog.networking.info("Forum operation=\(operationID, privacy: .public) attempt=\(number, privacy: .public) challenge")
            guard number == 1 else { throw ForumWAFFailure.replayExhausted }
            try Task.checkCancellation()
            try await context.validate()
            let result = try await recovery.recover(challenge: blocked.challenge, context: context, lease: policy.lease)
            try Task.checkCancellation()
            try await context.validate()
            guard policy.replay == .safeReadOnce else { throw ForumWAFFailure.replayNotPermitted }
            guard policy.lease.isValid else { throw ForumWAFFailure.runtimeUnavailable }
            let credentials = YamiboRequestCredentials(
                cookies: context.credentials.cookies.filter { !YamiboCookie.isWAFCookie($0.name) } + result.cookies,
                userAgent: context.key.userAgent
            )
            let replayNumber = try policy.operation.reserveAttempt(replay: policy.replay)
            YamiboLog.networking.info("Forum operation=\(operationID, privacy: .public) attempt=\(replayNumber, privacy: .public) replay")
            let replay = ForumRequestAttempt(operationID: operationID, number: replayNumber, context: context,
                                             credentials: credentials, lease: policy.lease)
            do {
                let result = try await transport(replay)
                try await context.validate()
                try Task.checkCancellation()
                YamiboLog.networking.info("Forum operation=\(operationID, privacy: .public) attempt=\(replayNumber, privacy: .public) success")
                return result
            } catch is ForumTransportChallenge {
                throw ForumWAFFailure.replayExhausted
            }
        }
    }
}

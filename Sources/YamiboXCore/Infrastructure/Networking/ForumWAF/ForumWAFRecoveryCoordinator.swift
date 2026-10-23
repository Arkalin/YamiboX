import Foundation

/// Shared by every transport, but only compatible sessions share a flight.
public actor ForumWAFRecoveryCoordinator {
    private struct Waiter {
        let continuation: CheckedContinuation<ForumWAFResult, any Error>
        let challenge: YamiboWAFChallenge
        let timeout: Task<Void, Never>
    }

    private struct Flight {
        let id: UUID
        let work: Task<Void, Never>
        let timeout: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private let verifier: any ForumSilentVerifying
    private var flights: [ForumSessionKey: Flight] = [:]
    private var clearances: [ForumSessionKey: ForumWAFResult] = [:]

    public init(verifier: any ForumSilentVerifying) {
        self.verifier = verifier
    }

    public func recover(
        challenge: YamiboWAFChallenge,
        context: ForumRequestContext,
        lease: ForumRuntimeLease
    ) async throws -> ForumWAFResult {
        try Task.checkCancellation()
        try await context.validate()
        guard context.key.origin.contains(challenge.url), challenge.userAgent == context.key.userAgent else {
            throw ForumWAFFailure.sessionInvalidated
        }
        guard lease.isValid else { throw ForumWAFFailure.runtimeUnavailable }
        let current = ForumWAFResult(cookies: try await context.currentWAFCookies())
        try await context.validate()
        try Task.checkCancellation()
        // A response from an old attempt may arrive after another flight commits.
        if current.hasUpdatedClearance(for: challenge) {
            YamiboLog.networking.info("Forum scope=\(context.key.scopeID, privacy: .public) clearance=reuse-current")
            return current
        }
        if let cached = clearances[context.key], cached.hasUpdatedClearance(for: challenge) {
            YamiboLog.networking.info("Forum scope=\(context.key.scopeID, privacy: .public) clearance=reuse-flight")
            return cached
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task {
                    do { try await ContinuousClock().sleep(until: lease.deadline) }
                    catch { return }
                    self.removeWaiter(waiterID, key: context.key, error: ForumWAFFailure.silentTimeout)
                }
                let waiter = Waiter(continuation: continuation, challenge: challenge, timeout: deadlineTask)
                if flights[context.key] != nil {
                    let id = flights[context.key]!.id
                    YamiboLog.networking.info("Forum scope=\(context.key.scopeID, privacy: .public) flight=\(id, privacy: .public) join")
                    flights[context.key]?.waiters[waiterID] = waiter
                    return
                }

                let flightID = UUID()
                YamiboLog.networking.info("Forum scope=\(context.key.scopeID, privacy: .public) flight=\(flightID, privacy: .public) start")
                let deadline = min(lease.deadline, ContinuousClock.now.advanced(by: .seconds(8)))
                let request = ForumSilentVerificationRequest(
                    flightID: flightID, key: context.key, challenge: challenge,
                    baseline: ForumWAFResult(cookies: context.credentials.cookies + current.cookies), deadline: deadline
                )
                let work = Task {
                    do {
                        let result = try await self.verifier.verify(request)
                        try Task.checkCancellation()
                        guard result.hasUpdatedClearance(for: challenge) else {
                            throw ForumWAFFailure.noUpdatedClearance
                        }
                        try await context.validate()
                        guard ContinuousClock.now < deadline else { throw ForumWAFFailure.silentTimeout }
                        try Task.checkCancellation()
                        try await context.commitWAFCookies(result)
                        try await context.validate()
                        try Task.checkCancellation()
                        self.clearances = self.clearances.filter { _, value in
                            value.cookies.contains { ($0.expiresAt ?? .distantPast) > .now }
                        }
                        if self.clearances.count >= 64 { self.clearances.removeAll() }
                        self.clearances[context.key] = result
                        self.finish(key: context.key, id: flightID, result: .success(result))
                    } catch {
                        let failure: any Error = error is ForumWAFFailure || error is CancellationError
                            ? error : ForumWAFFailure.runtimeUnavailable
                        self.finish(key: context.key, id: flightID, result: .failure(failure))
                    }
                }
                // Independent from verifier cooperation: a hung platform call
                // cannot keep continuations alive after the bounded deadline.
                let timeout = Task {
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    self.finish(key: context.key, id: flightID, result: .failure(ForumWAFFailure.silentTimeout))
                }
                flights[context.key] = Flight(id: flightID, work: work, timeout: timeout, waiters: [waiterID: waiter])
            }
        } onCancel: {
            Task { await self.removeWaiter(waiterID, key: context.key, error: CancellationError()) }
        }
    }

    public func invalidate(scopeID: UUID) {
        clearances = clearances.filter { $0.key.scopeID != scopeID }
        for (key, flight) in flights where key.scopeID == scopeID {
            finish(key: key, id: flight.id, result: .failure(ForumWAFFailure.sessionInvalidated))
        }
    }

    private func removeWaiter(_ id: UUID, key: ForumSessionKey, error: any Error) {
        guard let waiter = flights[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
        if let flight = flights[key] {
            YamiboLog.networking.info("Forum flight=\(flight.id, privacy: .public) waiter=\(id, privacy: .public) removed remaining=\(flight.waiters.count, privacy: .public)")
        }
        if flights[key]?.waiters.isEmpty == true, let flight = flights.removeValue(forKey: key) {
            flight.work.cancel()
            flight.timeout.cancel()
            let terminal = (error as? ForumWAFFailure)?.rawValue ?? "cancelled"
            YamiboLog.networking.info("Forum flight=\(flight.id, privacy: .public) terminal=\(terminal, privacy: .public) lastWaiterRemoved")
        }
    }

    private func finish(key: ForumSessionKey, id: UUID, result: Result<ForumWAFResult, any Error>) {
        guard flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
        let terminal: String
        switch result {
        case .success: terminal = "success"
        case .failure(let error): terminal = (error as? ForumWAFFailure)?.rawValue ?? "cancelled"
        }
        YamiboLog.networking.info("Forum flight=\(id, privacy: .public) terminal=\(terminal, privacy: .public)")
        flight.work.cancel()
        flight.timeout.cancel()
        for waiter in flight.waiters.values {
            waiter.timeout.cancel()
            if case let .success(result) = result, !result.hasUpdatedClearance(for: waiter.challenge) {
                waiter.continuation.resume(throwing: ForumWAFFailure.noUpdatedClearance)
            } else {
                waiter.continuation.resume(with: result)
            }
        }
    }
}

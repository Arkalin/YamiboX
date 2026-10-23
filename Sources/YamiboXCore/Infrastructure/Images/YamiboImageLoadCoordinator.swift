import CryptoKit
import Foundation

/// An in-memory request identity. Credentials never enter the persistent
/// failure cache; its identity excludes runtime generations and WAF churn.
public struct YamiboImageLoadContext: Hashable, Sendable {
    public let requestID: String
    public var imageRevision: UUID { imageEpoch ?? epoch }
    let failureKey: String
    let authenticationID: String
    let accountGeneration: UUID
    let epoch: UUID
    let imageEpoch: UUID?
    let recoveryEpoch: UUID?
    let credentials: YamiboRequestCredentials
    private(set) var recoveryRevision: UUID?

    public func recovering(_ revision: UUID?) -> Self {
        var copy = self
        copy.recoveryRevision = revision
        return copy
    }
}

struct YamiboCoverImageCoolingDown: Error, Sendable {
    let retryAfter: Date
}

/// A complete revision snapshot, so coalesced notifications cannot lose a
/// recovery for a second URL. Unrelated visible images retain their identity.
public struct YamiboImageLoadRevision: Sendable {
    public let epoch: UUID
    public let images: [String: UUID]
    public let recoveredCovers: [String: UUID]
    /// Retry hints for failed consumers only, not cache/request invalidations.
    public let verifiedImages: [String: UUID]
}

/// Owns network single-flight and cover-only negative caching. Keeping both
/// together counts a shared load (including a verified replay) only once.
actor YamiboImageLoadCoordinator {
    nonisolated let initialEpoch: UUID
    private struct Failure: Codable {
        var authenticationID: String
        var imageID: String
        var count: Int
        var updatedAt: Date
        var retryAfter: Date
    }

    private struct Snapshot: Codable {
        var version = 1
        var failures: [String: Failure]
    }

    private struct Flight {
        let id: UUID
        let source: YamiboImageSource
        let context: YamiboImageLoadContext
        let task: Task<Void, Never>
        var includesCover: Bool
        var waiters: [UUID: CheckedContinuation<Data, any Error>]
    }

    private struct VerificationFailure {
        let ticket: RecoveryTicket
        let imageID: String
        let notificationKey: String
        var notified = false
    }

    struct RecoveryTicket: Sendable {
        let requestContext: ForumRequestContext
        let operation: ForumRequestOperation
        let lease: ForumRuntimeLease
        let challenge: YamiboWAFChallenge
    }

    private let sessionStore: any SessionStoring
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let broadcaster = StoreInvalidationBroadcaster<YamiboImageLoadRevision>()
    private var loaded = false
    private var failures: [String: Failure] = [:]
    private var flights: [String: Flight] = [:]
    private var authenticationID: String?
    private var accountGeneration: UUID?
    private var epoch: UUID
    private var imageEpochs: [String: UUID] = [:]
    private var recoveryEpochs: [String: UUID] = [:]
    private var verificationFailures: [String: VerificationFailure] = [:]
    private var verifiedImages: [String: UUID] = [:]

    init(sessionStore: any SessionStoring, cacheDirectory: URL, now: @escaping @Sendable () -> Date = { .now }) {
        let epoch = UUID()
        self.initialEpoch = epoch
        self.epoch = epoch
        self.sessionStore = sessionStore
        self.fileURL = cacheDirectory.appendingPathComponent("cover-load-failures-v1.json")
        self.now = now
    }

    nonisolated func changes() -> AsyncStream<YamiboImageLoadRevision> { broadcaster.stream() }

    private func publishRevision() {
        broadcaster.post(YamiboImageLoadRevision(epoch: epoch, images: imageEpochs,
            recoveredCovers: recoveryEpochs, verifiedImages: verifiedImages))
    }

    func context(for source: YamiboImageSource) async throws -> YamiboImageLoadContext {
        let snapshot = try await sessionStore.snapshot()
        guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
        updateSession(snapshot)
        let source = source.normalizedForLoading
        let credentials = snapshot.session.credentials
        let authenticationID = Self.authenticationID(snapshot.session)
        let imageEpoch = imageEpochs[source.cacheKey]
        let referer = source.refererPageURL?.absoluteString ?? ""
        let header = credentials.cookieHeader(for: source.url)
        return YamiboImageLoadContext(
            requestID: Self.digest([source.cacheKey, referer, header, credentials.userAgent,
                epoch.uuidString, imageEpoch?.uuidString ?? ""]),
            failureKey: Self.digest([authenticationID, source.cacheKey, referer]),
            authenticationID: authenticationID, accountGeneration: snapshot.generation,
            epoch: epoch, imageEpoch: imageEpoch, recoveryEpoch: recoveryEpochs[source.cacheKey], credentials: credentials
        )
    }

    func sessionDidChange() async {
        guard let snapshot = try? await sessionStore.snapshot(),
              await sessionStore.isCurrentGeneration(snapshot.generation) else { return }
        updateSession(snapshot)
    }

    private func updateSession(_ snapshot: AccountSessionSnapshot) {
        let next = Self.authenticationID(snapshot.session)
        let changed = authenticationID != nil &&
            (authenticationID != next || accountGeneration != snapshot.generation)
        authenticationID = next
        accountGeneration = snapshot.generation
        guard changed else {
            // WAF-only updates must not clear caches or restart successful loads.
            recoverVerificationFailures(using: snapshot.session.credentials)
            return // A cold launch must retain its cover cooldown.
        }
        loadFailuresIfNeeded()
        failures = failures.filter { $0.value.authenticationID != next }
        epoch = UUID()
        imageEpochs.removeAll()
        recoveryEpochs.removeAll()
        verificationFailures.removeAll()
        verifiedImages.removeAll()
        cancelFlights { _ in true }
        persist()
        publishRevision()
    }

    func isCurrent(_ context: YamiboImageLoadContext, source: YamiboImageSource) async -> Bool {
        guard await sessionStore.isCurrentGeneration(context.accountGeneration) else { return false }
        return matches(context, source: source)
    }

    private func matches(_ context: YamiboImageLoadContext, source: YamiboImageSource) -> Bool {
        context.authenticationID == authenticationID && context.accountGeneration == accountGeneration
            && context.epoch == epoch && context.imageEpoch == imageEpochs[source.cacheKey]
    }

    func data(
        for source: YamiboImageSource, context: YamiboImageLoadContext,
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        try Task.checkCancellation()
        guard matches(context, source: source) else { throw CancellationError() }
        if source.purpose == .cover {
            loadFailuresIfNeeded()
            if let failure = failures[context.failureKey], failure.retryAfter > now() {
                throw YamiboCoverImageCoolingDown(retryAfter: failure.retryAfter)
            }
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if flights[context.requestID] != nil {
                    flights[context.requestID]?.waiters[waiterID] = continuation
                    if source.purpose == .cover { flights[context.requestID]?.includesCover = true }
                    return
                }
                // An active attempt handles its own verification/replay. It must
                // not also be restarted by an older failure's notification.
                let id = UUID()
                let task = Task { [weak self] in
                    let result: Result<Data, any Error>
                    do { result = .success(try await operation()) }
                    catch { result = .failure(error) }
                    await self?.complete(requestID: context.requestID, id: id, result: result)
                }
                flights[context.requestID] = Flight(id: id, source: source, context: context,
                    task: task, includesCover: source.purpose == .cover, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, requestID: context.requestID) }
        }
    }

    /// Only attempts that could not complete verification wait for another
    /// consumer to verify. A replay that is still blocked is deliberately final.
    func recordVerificationFailure(for source: YamiboImageSource, context: YamiboImageLoadContext, ticket: RecoveryTicket) async {
        guard await isCurrent(context, source: source),
              ticket.lease.isValid, ticket.operation.attemptCount == 1,
              verificationFailures.count < 2048 || verificationFailures[context.failureKey] != nil else { return }
        verificationFailures[context.failureKey] = VerificationFailure(ticket: ticket, imageID: source.cacheKey,
            notificationKey: source.recoveryKey)
        YamiboLog.networking.info("Forum operation=\(ticket.operation.id, privacy: .public) image-ticket=registered")
        // A WebKit update can win the race with this failure being recorded.
        await sessionDidChange()
    }

    func takeRecoveryTicket(context: YamiboImageLoadContext) throws -> RecoveryTicket? {
        guard let revision = context.recoveryRevision else {
            verificationFailures.removeValue(forKey: context.failureKey)
            return nil
        }
        guard let failure = verificationFailures[context.failureKey], failure.notified,
              verifiedImages[failure.notificationKey] == revision else { throw ForumWAFFailure.replayExhausted }
        // A delayed UI callback must fail closed, not mint a new operation.
        guard failure.ticket.lease.isValid else { throw ForumWAFFailure.runtimeUnavailable }
        guard failure.ticket.operation.attemptCount == 1 else { throw ForumWAFFailure.replayExhausted }
        guard failure.ticket.requestContext.key.generation == context.accountGeneration,
              failure.ticket.requestContext.key.userAgent == context.credentials.userAgent else { throw ForumWAFFailure.sessionInvalidated }
        YamiboLog.networking.info("Forum operation=\(failure.ticket.operation.id, privacy: .public) image-ticket=consumed")
        return failure.ticket
    }

    private func recoverVerificationFailures(using credentials: YamiboRequestCredentials) {
        guard !verificationFailures.isEmpty else { return }
        if verifiedImages.count >= 2048 {
            let active = Set(flights.values.map { $0.source.recoveryKey }).union(verificationFailures.values.map(\.notificationKey))
            verifiedImages = verifiedImages.filter { active.contains($0.key) }
        }
        var recovered = false
        for (key, failure) in verificationFailures {
            guard !failure.notified else { continue }
            guard failure.ticket.lease.isValid, failure.ticket.operation.attemptCount == 1 else {
                verificationFailures.removeValue(forKey: key)
                continue
            }
            guard !failure.notified, credentials.userAgent == failure.ticket.requestContext.key.userAgent,
                  ForumWAFResult(cookies: credentials.cookies).hasUpdatedClearance(for: failure.ticket.challenge) else { continue }
            verificationFailures[key]?.notified = true
            verifiedImages[failure.notificationKey] = UUID()
            YamiboLog.networking.info("Forum operation=\(failure.ticket.operation.id, privacy: .public) image-ticket=notified")
            recovered = true
        }
        if recovered { publishRevision() }
    }

    private static func clearanceID(_ credentials: YamiboRequestCredentials, for url: URL) -> String? {
        guard let cookie = credentials.cookies.first(where: { $0.name == "nox_jst_v1" && $0.matches(url) }) else { return nil }
        return digest([cookie.identity, cookie.value, cookie.expiresAt.map { String($0.timeIntervalSince1970) } ?? "",
            credentials.userAgent])
    }

    private func complete(requestID: String, id: UUID, result: Result<Data, any Error>) async {
        guard let current = flights[requestID], current.id == id else { return }
        let valid = await isCurrent(current.context, source: current.source)
        // Account/cover changes may have removed the flight during the await.
        guard let flight = flights[requestID], flight.id == id else { return }
        flights.removeValue(forKey: requestID)
        guard valid, matches(flight.context, source: flight.source) else {
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
            return
        }
        if flight.includesCover, flight.context.recoveryEpoch == recoveryEpochs[flight.source.cacheKey],
           case let .failure(error) = result,
           !LoadDiagnosticError.isCancellation(error), LoadFailureDetails(error: error).httpStatus == 403 {
            loadFailuresIfNeeded()
            let date = now()
            let previous = failures[flight.context.failureKey]
            let count = min(3, (previous.map { date.timeIntervalSince($0.updatedAt) <= 7 * 86400 ? $0.count : 0 } ?? 0) + 1)
            let delay: TimeInterval = count == 1 ? 1800 : count == 2 ? 7200 : 21600
            failures[flight.context.failureKey] = Failure(authenticationID: flight.context.authenticationID,
                imageID: Self.digest([flight.source.cacheKey]), count: count,
                updatedAt: date, retryAfter: date.addingTimeInterval(delay))
            persist()
        }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func cancelWaiter(_ waiterID: UUID, requestID: String) {
        guard let continuation = flights[requestID]?.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        if flights[requestID]?.waiters.isEmpty == true {
            flights.removeValue(forKey: requestID)?.task.cancel()
        }
    }

    /// Decoding, not just a 200 response, establishes a usable image. A reader
    /// or a different thumbnail variant can recover every failed cover of it.
    func didDecode(_ source: YamiboImageSource, context: YamiboImageLoadContext) async {
        guard await isCurrent(context, source: source) else { return }
        verificationFailures = verificationFailures.filter { $0.value.imageID != source.cacheKey }
        loadFailuresIfNeeded()
        let imageID = Self.digest([source.cacheKey])
        let hadFailures = failures.values.contains {
            $0.authenticationID == context.authenticationID && $0.imageID == imageID
        }
        failures = failures.filter {
            $0.value.authenticationID != context.authenticationID || $0.value.imageID != imageID
        }
        // A successful reader must not cancel other reader consumers. Mark
        // older in-flight 403 results stale independently of request validity.
        let hasOlderCoverFlight = flights.values.contains {
            $0.includesCover && $0.source.cacheKey == source.cacheKey
        }
        guard hadFailures || hasOlderCoverFlight else { return }
        if recoveryEpochs.count >= 2048, recoveryEpochs[source.cacheKey] == nil {
            let activeURLs = Set(flights.values.map { $0.source.cacheKey })
            recoveryEpochs = recoveryEpochs.filter { activeURLs.contains($0.key) }
        }
        recoveryEpochs[source.cacheKey] = UUID()
        if hadFailures { persist() }
        publishRevision()
    }

    func invalidateCovers(_ urls: Set<URL>?) {
        loadFailuresIfNeeded()
        let ids = urls.map { Set($0.map { Self.digest([$0.absoluteString]) }) }
        failures = failures.filter { entry in
            if let ids { return !ids.contains(entry.value.imageID) }
            return false
        }
        invalidateFlights(for: urls)
        persist()
        publishRevision()
    }

    /// Clearing temporary bytes must not reset a cover's authentication-aware
    /// retry policy or remove retained artwork.
    func invalidateTransientLoads() {
        invalidateFlights(for: nil)
        publishRevision()
    }

    private func invalidateFlights(for urls: Set<URL>?) {
        if let urls {
            let ids = Set(urls.map(\.absoluteString))
            for (key, failure) in verificationFailures where ids.contains(failure.imageID) {
                verificationFailures.removeValue(forKey: key)
                verifiedImages.removeValue(forKey: failure.notificationKey)
            }
        } else {
            verificationFailures.removeAll()
            verifiedImages.removeAll()
        }
        if let urls, imageEpochs.count + urls.count <= 2048 {
            for url in urls {
                imageEpochs[url.absoluteString] = UUID()
                recoveryEpochs.removeValue(forKey: url.absoluteString)
            }
            cancelFlights { urls.contains($0.source.url) }
        } else {
            epoch = UUID()
            imageEpochs.removeAll()
            recoveryEpochs.removeAll()
            cancelFlights { _ in true }
        }
    }

    private func cancelFlights(where predicate: (Flight) -> Bool) {
        let keys = flights.filter { predicate($0.value) }.map(\.key)
        for key in keys {
            guard let flight = flights.removeValue(forKey: key) else { continue }
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    private func loadFailuresIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            failures = snapshot.failures
            prune()
        } catch {
            failures = [:]
            YamiboLog.persistence.warning("Ignoring unreadable cover failure cache: \(error)")
        }
    }

    private func prune() {
        let date = now()
        failures = failures.filter { _, entry in
            (1...3).contains(entry.count) && entry.updatedAt.timeIntervalSince1970.isFinite
                && entry.retryAfter.timeIntervalSince1970.isFinite
                && date.timeIntervalSince(entry.updatedAt) <= 7 * 86400
                && entry.retryAfter.timeIntervalSince(date) <= 21600
        }
        if failures.count > 2048 {
            failures = Dictionary(uniqueKeysWithValues: failures.sorted {
                $0.value.updatedAt > $1.value.updatedAt
            }.prefix(2048).map { ($0.key, $0.value) })
        }
    }

    private func persist() {
        prune()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Snapshot(failures: failures))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            YamiboLog.persistence.warning("Cover failure cache is memory-only after a write failure: \(error)")
        }
    }

    private static func authenticationID(_ session: SessionState) -> String {
        digest([YamiboDomain.baseURL.absoluteString, session.accountUID ?? "", session.isLoggedIn ? "1" : "0",
            session.authenticationCookie?.value ?? ""])
    }

    private static func digest(_ parts: [String]) -> String {
        // Length-prefixing avoids ambiguous component boundaries without
        // normalizing away meaningful URL query parameters.
        let data = Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

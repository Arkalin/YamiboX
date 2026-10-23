import Foundation

/// An exact origin, never a hostname suffix or a Cookie domain.
public struct ForumOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    public func contains(_ url: URL) -> Bool { ForumOrigin(url: url) == self }
}

public enum ForumReplayPolicy: Sendable {
    case never
    case safeReadOnce
}

/// A lease cannot be extended by joining an existing verification flight.
public struct ForumRuntimeLease: Sendable {
    public let deadline: ContinuousClock.Instant

    public init(duration: Duration) {
        deadline = ContinuousClock.now.advanced(by: duration)
    }

    public var isValid: Bool { ContinuousClock.now < deadline }
}

public struct ForumRequestPolicy: Sendable {
    public let replay: ForumReplayPolicy
    public let lease: ForumRuntimeLease
    public let operation: ForumRequestOperation
    let deliversCompletedInitialResponse: Bool

    public init(replay: ForumReplayPolicy = .never, lease: ForumRuntimeLease, operation: ForumRequestOperation = .init(), deliversCompletedInitialResponse: Bool = false) {
        self.replay = replay
        self.lease = lease
        self.operation = operation
        self.deliversCompletedInitialResponse = deliversCompletedInitialResponse
    }
}

/// Retained by a recovery ticket, never recreated by a Cookie notification.
public final class ForumRequestOperation: @unchecked Sendable {
    public let id = UUID()
    private let lock = NSLock()
    private var count = 0

    public init() {}
    var attemptCount: Int { lock.withLock { count } }
    func reserveAttempt(replay: ForumReplayPolicy) throws -> Int {
        try lock.withLock {
            guard count < (replay == .safeReadOnce ? 2 : 1) else { throw ForumWAFFailure.replayExhausted }
            count += 1
            return count
        }
    }
}

public struct ForumTransportCapabilities: Sendable {
    public static let controlledNative = Self(observesRedirectsBeforeFollowing: true, supportsIncrementalDelivery: true, survivesProcessExit: false)
    public static let backgroundDownload = Self(observesRedirectsBeforeFollowing: false, supportsIncrementalDelivery: true, survivesProcessExit: true)
    public let observesRedirectsBeforeFollowing: Bool
    public let supportsIncrementalDelivery: Bool
    public let survivesProcessExit: Bool

    public init(
        observesRedirectsBeforeFollowing: Bool,
        supportsIncrementalDelivery: Bool,
        survivesProcessExit: Bool
    ) {
        self.observesRedirectsBeforeFollowing = observesRedirectsBeforeFollowing
        self.supportsIncrementalDelivery = supportsIncrementalDelivery
        self.survivesProcessExit = survivesProcessExit
    }

    public func admits(url: URL, context: ForumRequestContext, lease: ForumRuntimeLease) -> Bool {
        lease.isValid && (observesRedirectsBeforeFollowing || !context.key.origin.contains(url))
    }
}

/// Scope identifies the owner, not merely the logged-in account UID. Candidate
/// and retired sessions must have distinct scope and Cookie storage identities.
public struct ForumSessionKey: Hashable, Sendable {
    public let origin: ForumOrigin
    public let scopeID: UUID
    public let generation: UUID
    public let cookieStorageID: UUID
    public let userAgent: String

    public init(origin: ForumOrigin, scopeID: UUID, generation: UUID, cookieStorageID: UUID, userAgent: String) {
        self.origin = origin
        self.scopeID = scopeID
        self.generation = generation
        self.cookieStorageID = cookieStorageID
        self.userAgent = userAgent
    }
}

/// The commit closure must check the expected generation and merge WAF cookies
/// in the same storage transaction. A separate check followed by save is unsafe.
public struct ForumRequestContext: Sendable {
    public let key: ForumSessionKey
    public let credentials: YamiboRequestCredentials
    let validate: @Sendable () async throws -> Void
    let currentWAFCookies: @Sendable () async throws -> [YamiboCookie]
    let commitWAFCookies: @Sendable (ForumWAFResult) async throws -> Void

    public init(
        key: ForumSessionKey,
        credentials: YamiboRequestCredentials,
        validate: @escaping @Sendable () async throws -> Void,
        currentWAFCookies: @escaping @Sendable () async throws -> [YamiboCookie],
        commitWAFCookies: @escaping @Sendable (ForumWAFResult) async throws -> Void
    ) {
        self.key = key
        self.credentials = YamiboRequestCredentials(cookies: credentials.cookies, userAgent: key.userAgent)
        self.validate = validate
        self.currentWAFCookies = currentWAFCookies
        self.commitWAFCookies = commitWAFCookies
    }
}

/// A transport receives this value from the executor; it cannot mint another
/// attempt or reset a logical operation's replay budget.
public struct ForumRequestAttempt: Sendable {
    public let operationID: UUID
    public let number: Int
    public let context: ForumRequestContext
    public let credentials: YamiboRequestCredentials
    public let lease: ForumRuntimeLease

    init(operationID: UUID, number: Int, context: ForumRequestContext,
         credentials: YamiboRequestCredentials, lease: ForumRuntimeLease) {
        self.operationID = operationID
        self.number = number
        self.context = context
        self.credentials = credentials
        self.lease = lease
    }
}

/// Required dependency at native forum call sites. Even unavailable platform
/// verification is represented by a verifier, never by an optional executor.
public protocol ForumRequestExecuting: Sendable {
    func execute<Value: Sendable>(
        context: ForumRequestContext,
        policy: ForumRequestPolicy,
        transport: @escaping @Sendable (ForumRequestAttempt) async throws -> Value
    ) async throws -> Value
}

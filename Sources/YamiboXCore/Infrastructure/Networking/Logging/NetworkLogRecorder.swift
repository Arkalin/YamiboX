import Foundation

final class NetworkLogGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()
    private var clearedAt: Date?

    func snapshot() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func advance() -> Date {
        lock.lock()
        defer { lock.unlock() }
        value = UUID()
        let date = Date()
        clearedAt = date
        return date
    }

    func restoreClearDate(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        clearedAt = max(clearedAt ?? .distantPast, date)
    }

    func accepts(_ generation: UUID, startedAt: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value && (clearedAt.map { startedAt >= $0 } ?? true)
    }
}

public final class NetworkLogToken: @unchecked Sendable {
    public let id = UUID()
    public let source: NetworkLogSource
    public let startedAt: Date
    let generation: UUID
    let method: String
    let initialURL: String
    let startedUptime: TimeInterval

    private let lock = NSLock()
    private var redirects: [NetworkLogRedirect] = []
    private var truncated: Bool
    private var finished = false

    init(request: URLRequest, source: NetworkLogSource, startedAt: Date, generation: UUID) {
        self.source = source
        self.startedAt = startedAt
        self.generation = generation
        method = NetworkLogRedactor.method(request.httpMethod)
        let url = NetworkLogRedactor.url(request.url, source: source)
        initialURL = url.value ?? "[UNKNOWN]"
        truncated = url.truncated
        startedUptime = ProcessInfo.processInfo.systemUptime - max(0, Date().timeIntervalSince(startedAt))
    }

    func addRedirect(fromURL: URL?, toURL: URL?, statusCode: Int?) {
        let from = NetworkLogRedactor.url(fromURL, source: source)
        let to = NetworkLogRedactor.url(toURL, source: source)
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        truncated = truncated || from.truncated || to.truncated
        guard redirects.count < 32 else { truncated = true; return }
        redirects.append(NetworkLogRedirect(
            fromURL: from.value ?? redirects.last?.toURL ?? initialURL,
            toURL: to.value, statusCode: statusCode
        ))
    }

    func complete(
        response: URLResponse?, sentBytes: Int64?, receivedBytes: Int64?,
        error: (any Error)?, finalURL: URL?, duration: TimeInterval?, startedAt: Date?
    ) -> NetworkLogEntry? {
        let final = NetworkLogRedactor.url(finalURL ?? response?.url, source: source)
        let failure = error.map { NetworkLogError(error: $0) }
        let elapsed = duration ?? ProcessInfo.processInfo.systemUptime - startedUptime
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return NetworkLogEntry(
            id: id, source: source, startedAt: startedAt ?? self.startedAt,
            duration: elapsed.isFinite ? max(0, elapsed) : 0,
            method: method, initialURL: initialURL, finalURL: final.value,
            redirects: redirects, statusCode: (response as? HTTPURLResponse)?.statusCode,
            sentBytes: sentBytes.flatMap { $0 >= 0 ? $0 : nil },
            receivedBytes: receivedBytes.flatMap { $0 >= 0 ? $0 : nil },
            error: failure, truncated: truncated || final.truncated
        )
    }
}

/// Transport callbacks never wait for disk, retain credentials, or throw because
/// of logging. All retained token state is already sanitized.
public final class NetworkLogRecorder: Sendable {
    public static let shared = NetworkLogRecorder(store: .shared)
    private let store: NetworkLogStore

    public init(store: NetworkLogStore) {
        self.store = store
        Task { _ = try? await store.usageBytes() }
    }

    public func begin(
        request: URLRequest, source: NetworkLogSource, startedAt: Date = Date()
    ) -> NetworkLogToken {
        NetworkLogToken(request: request, source: source, startedAt: startedAt, generation: store.generation.snapshot())
    }

    public func addRedirect(to token: NetworkLogToken, from response: HTTPURLResponse, request: URLRequest) {
        token.addRedirect(fromURL: response.url, toURL: request.url, statusCode: response.statusCode)
    }

    public func addRedirect(to token: NetworkLogToken, url: URL, statusCode: Int? = nil) {
        token.addRedirect(fromURL: nil, toURL: url, statusCode: statusCode)
    }

    public func finish(
        _ token: NetworkLogToken, response: URLResponse? = nil,
        sentBytes: Int64? = nil, receivedBytes: Int64? = nil,
        error: (any Error)? = nil, finalURL: URL? = nil, duration: TimeInterval? = nil,
        startedAt: Date? = nil
    ) {
        guard let entry = token.complete(
            response: response, sentBytes: sentBytes, receivedBytes: receivedBytes,
            error: error, finalURL: finalURL, duration: duration, startedAt: startedAt
        ) else { return }
        let generation = token.generation
        Task { try? await store.append(entry, generation: generation) }
    }
}

import Foundation

public final class DownloadBackgroundTransport: NSObject, DownloadImageTransporting, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let defaultIdentifier = YamiboForumEnvironment.current.backgroundDownloadIdentifier

    private let lock = NSLock()
    private let sessionFactory: @Sendable (URLSessionDelegate) -> URLSession
    private var sessionStorage: URLSession?
    private var invalidationContinuation: CheckedContinuation<Void, Never>?
    private var pendingDownloads: [Int: PendingDownload] = [:]
    private var networkLogs: [Int: DownloadNetworkLog] = [:]
    private var unstartedTaskIdentifiers: Set<Int> = []
    private var backgroundEventCompletionHandlers: [String: () -> Void] = [:]
    private let sessionStore: any SessionStoring
    private let requestExecutor: ForumRequestExecutor
    private let controlledSession = YamiboNetworkConfiguration.makeSession()

    public init(
        configuration: URLSessionConfiguration = DownloadBackgroundTransport.makeBackgroundConfiguration(),
        delegateQueue: OperationQueue? = nil,
        sessionStore: any SessionStoring = SessionStore(),
        requestExecutor: ForumRequestExecutor = .unavailable
    ) {
        let queue = delegateQueue ?? OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.sessionStore = sessionStore
        self.requestExecutor = requestExecutor
        sessionFactory = { delegate in
            URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        }
        super.init()
    }

    init(
        sessionFactory: @escaping @Sendable (URLSessionDelegate) -> URLSession,
        sessionStore: any SessionStoring = SessionStore(),
        requestExecutor: ForumRequestExecutor = .unavailable
    ) {
        self.sessionFactory = sessionFactory
        self.sessionStore = sessionStore
        self.requestExecutor = requestExecutor
        super.init()
    }

    public static func makeBackgroundConfiguration(
        identifier: String = defaultIdentifier
    ) -> URLSessionConfiguration {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = YamiboForumEnvironment.current.supportsBackgroundRelaunch
        configuration.isDiscretionary = false
        #else
        let configuration = URLSessionConfiguration.default
        #endif
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.allowsCellularAccess = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    public func downloadImageData(for source: YamiboImageSource) async throws -> Data {
        try await downloadImageData(for: source, progress: { _ in })
    }

    func downloadImageData(
        for source: YamiboImageSource,
        progress: @escaping @Sendable (DownloadTransferProgress) -> Void
    ) async throws -> Data {
        await DownloadBackgroundSessionMigration.shared.retire()
        let snapshot = try await sessionStore.snapshot()
        let context = sessionStore.forumRequestContext(snapshot: snapshot)
        return try await requestExecutor.execute(context: context,
            policy: .init(replay: .safeReadOnce, lease: .init(duration: .seconds(40)))) { [self] attempt in
            // Background URLSession follows redirects without a per-hop veto.
            // Forum requests therefore use the controlled, cancellable adapter.
            guard attempt.lease.isValid else { throw ForumWAFFailure.runtimeUnavailable }
            if !ForumTransportCapabilities.backgroundDownload.admits(url: source.url, context: attempt.context, lease: attempt.lease) {
                var request = URLRequest(url: source.url)
                YamiboNetworkPolicy.applyCredentials(attempt.credentials, to: &request, handlesCookies: false)
                request.setValue(source.refererPageURL?.absoluteString, forHTTPHeaderField: "Referer")
                request.timeoutInterval = 15
                let response = try await ForumDataTransport.data(request: request, attempt: attempt,
                    session: controlledSession, delegate: nil,
                    bodyPolicy: .init(prefixByteCount: 512) { response, _ in
                        NetworkResponseBodyLimit(maximumBytes: 50 * 1024 * 1024,
                            error: YamiboError.invalidResponse(statusCode: response.statusCode))
                    }, progress: { received, expected in
                        progress(.init(receivedBytes: received, expectedBytes: expected))
                    })
                guard 200..<300 ~= response.response.statusCode else {
                    throw YamiboError.invalidResponse(statusCode: response.response.statusCode)
                }
                return response.data
            }
            return try await backgroundAttempt(for: source, attempt: attempt, progress: progress)
        }
    }

    private func backgroundAttempt(for source: YamiboImageSource, attempt: ForumRequestAttempt,
                                   progress: @escaping @Sendable (DownloadTransferProgress) -> Void) async throws -> Data {
        try Task.checkCancellation()
        let taskBox = URLSessionTaskBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var urlRequest = URLRequest(url: source.url)
                // Only public external resources use this adapter. No account,
                // WAF, Referer or shared jar can follow its invisible redirects.
                urlRequest.httpShouldHandleCookies = false
                urlRequest.setValue(attempt.context.key.userAgent, forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: urlRequest)
                lock.withLock { _ = unstartedTaskIdentifiers.insert(task.taskIdentifier) }
                task.taskDescription = source.url.absoluteString
                let admitted = taskBox.admit(task) {
                    guard !Task.isCancelled else { return false }
                    register(
                        taskIdentifier: task.taskIdentifier,
                        task: task,
                        attempt: attempt,
                        continuation: continuation,
                        progress: progress,
                        logToken: NetworkLogRecorder.shared.begin(request: urlRequest, source: .download)
                    )
                    task.resume()
                    return true
                }
                guard admitted else {
                    lock.withLock { _ = unstartedTaskIdentifiers.remove(task.taskIdentifier) }
                    continuation.resume(throwing: CancellationError())
                    return
                }
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    public func cancelAllDownloads() {
        controlledSession.getAllTasks { $0.forEach { $0.cancel() } }
        let tasks = lock.withLock { pendingDownloads.values.compactMap(\.task) }
        tasks.forEach { $0.cancel() }
    }

    /// Used only by startup reset, before any new downloads can be submitted.
    func invalidateRestoredDownloads() async {
        await withCheckedContinuation { continuation in
            lock.withLock { invalidationContinuation = continuation }
            session.invalidateAndCancel()
        }
    }

    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let continuation = lock.withLock {
            let continuation = invalidationContinuation
            invalidationContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    public func setBackgroundEventsCompletionHandler(
        _ completionHandler: @escaping () -> Void,
        forSessionIdentifier identifier: String
    ) {
        lock.withLock {
            backgroundEventCompletionHandlers[identifier] = completionHandler
        }
        _ = session
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        let completionHandler = lock.withLock {
            backgroundEventCompletionHandlers.removeValue(forKey: identifier)
        }
        completionHandler?()
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        _ = networkLog(for: downloadTask)
        let report = lock.withLock { pendingDownloads[downloadTask.taskIdentifier]?.progress }
        report?(DownloadTransferProgress(receivedBytes: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        _ = networkLog(for: downloadTask)
        guard lock.withLock({ pendingDownloads[downloadTask.taskIdentifier] != nil }) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw YamiboError.invalidResponse(statusCode: nil)
            }
            let file = try FileHandle(forReadingFrom: location)
            defer { try? file.close() }
            let prefix = try file.read(upToCount: ForumWAFResponseClassifier.maximumBodyBytes) ?? Data()
            lock.withLock {
                pendingDownloads[downloadTask.taskIdentifier]?.response = response
                pendingDownloads[downloadTask.taskIdentifier]?.prefix = prefix
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 50 * 1024 * 1024,
                  200..<300 ~= response.statusCode else { throw YamiboError.invalidResponse(statusCode: (downloadTask.response as? HTTPURLResponse)?.statusCode) }
            let data = try Data(contentsOf: location)
            lock.withLock { pendingDownloads[downloadTask.taskIdentifier]?.result = .success(data) }
        } catch {
            lock.withLock { pendingDownloads[downloadTask.taskIdentifier]?.result = .failure(error) }
        }
        // Foundation owns and removes `location` after this callback. Retain
        // only the bounded classification prefix and a normal resource result.
        finishIfReady(taskIdentifier: downloadTask.taskIdentifier)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        lock.withLock {
            unstartedTaskIdentifiers.remove(task.taskIdentifier)
            pendingDownloads[task.taskIdentifier]?.completionReceived = true
            pendingDownloads[task.taskIdentifier]?.completionError = error.map(Self.downloadError(from:))
        }
        finishIfReady(taskIdentifier: task.taskIdentifier)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let redirectedRequest = YamiboNetworkPolicy.redirectedRequest(request, from: task.originalRequest?.url)
        if let redirectedRequest, let log = networkLog(for: task) {
            NetworkLogRecorder.shared.addRedirect(to: log.token, from: response, request: redirectedRequest)
        }
        completionHandler(redirectedRequest)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let log = networkLog(for: task) else { return }
        lock.withLock {
            networkLogs[task.taskIdentifier]?.startedAt = metrics.taskInterval.start
            networkLogs[task.taskIdentifier]?.duration = metrics.taskInterval.duration
            pendingDownloads[task.taskIdentifier]?.metricsReceived = true
        }
        // Background sessions follow redirects without calling the redirect
        // delegate. Their transaction metrics are the source of actual hops;
        // foreground sessions already recorded those callbacks above.
        let attempt = lock.withLock { pendingDownloads[task.taskIdentifier]?.attempt }
        var evidence = attempt.flatMap { attempt in
            task.originalRequest?.url.map { ForumRedirectEvidence(origin: attempt.context.key.origin, originalURL: $0) }
        }
        for (transaction, next) in zip(metrics.transactionMetrics, metrics.transactionMetrics.dropFirst()) {
            guard let response = transaction.response as? HTTPURLResponse,
                  300 ..< 400 ~= response.statusCode,
                  response.statusCode != 304 else { continue }
            if session.configuration.identifier != nil {
                NetworkLogRecorder.shared.addRedirect(to: log.token, from: response, request: next.request)
            }
            if let from = response.url, let to = next.request.url { evidence?.observe(from: from, to: to) }
        }
        lock.withLock { pendingDownloads[task.taskIdentifier]?.leftOrigin = evidence?.leftOrigin ?? true }
        if let evidence, let url = evidence.challengeURL, let attempt, let request = task.originalRequest {
            lock.withLock {
                pendingDownloads[task.taskIdentifier]?.validationFailure = ForumTransportChallenge(
                    challenge: ForumWAFResponseClassifier.challenge(url: url, request: request, credentials: attempt.credentials))
            }
        }
        finishIfReady(taskIdentifier: task.taskIdentifier)
    }

    private var session: URLSession {
        lock.withLock {
            if let sessionStorage {
                return sessionStorage
            }
            let session = sessionFactory(self)
            sessionStorage = session
            // No trusted pending/lease survives relaunch. Persisted queue work
            // remains available for an explicit new run, not an invented replay.
            session.getAllTasks { [weak self] tasks in
                for task in tasks where task.state != .completed {
                    guard let self else { task.cancel(); continue }
                    let trusted = self.lock.withLock {
                        self.pendingDownloads[task.taskIdentifier] != nil || self.unstartedTaskIdentifiers.contains(task.taskIdentifier)
                    }
                    if !trusted {
                        YamiboLog.networking.info("Forum background task=\(task.taskIdentifier, privacy: .public) rejected=missingContext")
                        task.cancel()
                    }
                }
            }
            return session
        }
    }

    private func register(
        taskIdentifier: Int,
        task: URLSessionTask,
        attempt: ForumRequestAttempt,
        continuation: CheckedContinuation<Data, any Error>,
        progress: @escaping @Sendable (DownloadTransferProgress) -> Void,
        logToken: NetworkLogToken
    ) {
        lock.withLock {
            pendingDownloads[taskIdentifier] = PendingDownload(continuation: continuation, task: task, progress: progress, attempt: attempt)
            pendingDownloads[taskIdentifier]?.deadlineTask = Task { [weak self, weak task] in
                do { try await ContinuousClock().sleep(until: attempt.lease.deadline) }
                catch { return }
                self?.lock.withLock {
                    self?.pendingDownloads[taskIdentifier]?.validationFailure = ForumWAFFailure.runtimeUnavailable
                }
                task?.cancel()
                self?.complete(taskIdentifier: taskIdentifier, result: .failure(ForumWAFFailure.runtimeUnavailable))
            }
            unstartedTaskIdentifiers.remove(taskIdentifier)
            networkLogs[taskIdentifier] = DownloadNetworkLog(token: logToken)
        }
    }

    private func networkLog(for task: URLSessionTask) -> DownloadNetworkLog? {
        lock.withLock { networkLogs[task.taskIdentifier] }
    }

    private func finishIfReady(taskIdentifier: Int) {
        let result: Result<Data, any Error>? = lock.withLock {
            guard let pending = pendingDownloads[taskIdentifier], pending.completionReceived else { return nil }
            // Cancellation and ordinary failures do not wait for metrics that
            // Foundation may omit. Successful files require all three signals.
            if let failure = pending.validationFailure { return .failure(failure) }
            if let error = pending.completionError { return .failure(error) }
            guard pending.metricsReceived, let result = pending.result else { return nil }
            if let response = pending.response, let request = pending.task?.originalRequest,
               let originalURL = request.url,
               ForumWAFResponseClassifier.matches(response: response, prefix: pending.prefix,
                   origin: pending.attempt.context.key.origin, originalURL: originalURL, leftOrigin: pending.leftOrigin),
               let url = response.url {
                return .failure(ForumTransportChallenge(challenge: ForumWAFResponseClassifier.challenge(
                    url: url, request: request, credentials: pending.attempt.credentials)))
            }
            return result
        }
        if let result { complete(taskIdentifier: taskIdentifier, result: result) }
    }

    private func complete(taskIdentifier: Int, result: Result<Data, any Error>) {
        let pending = lock.withLock {
            pendingDownloads.removeValue(forKey: taskIdentifier)
        }
        guard let pending else { return }
        pending.deadlineTask?.cancel()
        let log = lock.withLock { networkLogs.removeValue(forKey: taskIdentifier) }
        if let log, let task = pending.task {
            let error: (any Error)?
            if case let .failure(failure) = result { error = failure } else { error = nil }
            NetworkLogRecorder.shared.finish(log.token, response: task.response,
                sentBytes: task.countOfBytesSent, receivedBytes: task.countOfBytesReceived, error: error,
                finalURL: task.currentRequest?.url, duration: log.duration, startedAt: log.startedAt)
        }

        switch result {
        case let .success(data):
            pending.continuation.resume(returning: data)
        case let .failure(error):
            pending.continuation.resume(throwing: error)
        }
    }

    private static func downloadError(from error: any Error) -> any Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return CancellationError()
        }
        return error
    }
}

private struct DownloadNetworkLog {
    let token: NetworkLogToken
    var startedAt: Date?
    var duration: TimeInterval?
}

private struct PendingDownload {
    var continuation: CheckedContinuation<Data, any Error>
    var task: URLSessionTask?
    var progress: @Sendable (DownloadTransferProgress) -> Void
    let attempt: ForumRequestAttempt
    var result: Result<Data, any Error>?
    var validationFailure: (any Error)?
    var deadlineTask: Task<Void, Never>?
    var response: HTTPURLResponse?
    var prefix = Data()
    var leftOrigin = true
    var metricsReceived = false
    var completionReceived = false
    var completionError: (any Error)?
}

private final class URLSessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    /// Atomically admits the task and its registration/start sequence. A
    /// cancellation that wins before admission cannot leave a task waiting
    /// behind credentials and then start a transfer after the caller paused.
    func admit(_ task: URLSessionTask, start: () -> Bool) -> Bool {
        lock.withLock {
            guard !isCancelled else {
                task.cancel()
                return false
            }
            self.task = task
            guard start() else {
                task.cancel()
                self.task = nil
                return false
            }
            return true
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// Kept instead of Foundation's `NSLocking.withLock` because that overload
/// constrains the result to `Sendable`, which some lock-protected values here
/// don't satisfy (e.g. the plain `() -> Void` background-event completion
/// handlers). One internal copy serves every downloads call site;
/// call sites with a Sendable result may still resolve to either overload —
/// the two behave identically.
extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

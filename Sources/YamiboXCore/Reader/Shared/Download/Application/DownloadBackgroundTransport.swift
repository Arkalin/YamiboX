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
    private let sessionStore: (any SessionStoring)?

    public init(
        configuration: URLSessionConfiguration = DownloadBackgroundTransport.makeBackgroundConfiguration(),
        delegateQueue: OperationQueue? = nil,
        sessionStore: (any SessionStoring)? = nil
    ) {
        let queue = delegateQueue ?? OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.sessionStore = sessionStore
        sessionFactory = { delegate in
            URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        }
        super.init()
    }

    init(
        sessionFactory: @escaping @Sendable (URLSessionDelegate) -> URLSession,
        sessionStore: (any SessionStoring)? = nil
    ) {
        self.sessionFactory = sessionFactory
        self.sessionStore = sessionStore
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
        try Task.checkCancellation()
        let taskBox = URLSessionTaskBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let credentials = await currentCredentials()
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var urlRequest = URLRequest(url: source.url)
                if let credentials {
                    YamiboNetworkPolicy.applyCredentials(credentials, to: &urlRequest)
                }
                if let refererPageURL = source.refererPageURL {
                    urlRequest.setValue(refererPageURL.absoluteString, forHTTPHeaderField: "Referer")
                }
                let task = session.downloadTask(with: urlRequest)
                lock.withLock { _ = unstartedTaskIdentifiers.insert(task.taskIdentifier) }
                task.taskDescription = source.url.absoluteString
                let admitted = taskBox.admit(task) {
                    guard !Task.isCancelled else { return false }
                    register(
                        taskIdentifier: task.taskIdentifier,
                        task: task,
                        continuation: continuation,
                        progress: progress,
                        logToken: NetworkLogRecorder.shared.begin(request: urlRequest, source: .download)
                    )
                    task.resume()
                    return true
                }
                guard admitted else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    public func cancelAllDownloads() {
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
        do {
            let data = try Data(contentsOf: location)
            complete(taskIdentifier: downloadTask.taskIdentifier, result: .success(data))
        } catch {
            complete(taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let log = networkLog(for: task) {
            _ = lock.withLock { networkLogs.removeValue(forKey: task.taskIdentifier) }
            NetworkLogRecorder.shared.finish(
                log.token,
                response: task.response,
                sentBytes: task.countOfBytesSent,
                receivedBytes: task.countOfBytesReceived,
                error: error,
                finalURL: task.currentRequest?.url,
                duration: log.duration,
                startedAt: log.startedAt
            )
        }
        lock.withLock { _ = unstartedTaskIdentifiers.remove(task.taskIdentifier) }
        guard let error else { return }
        complete(taskIdentifier: task.taskIdentifier, result: .failure(Self.downloadError(from: error)))
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
        }
        // Background sessions follow redirects without calling the redirect
        // delegate. Their transaction metrics are the source of actual hops;
        // foreground sessions already recorded those callbacks above.
        guard session.configuration.identifier != nil, metrics.redirectCount > 0 else { return }
        for (transaction, next) in zip(metrics.transactionMetrics, metrics.transactionMetrics.dropFirst()) {
            guard let response = transaction.response as? HTTPURLResponse,
                  300 ..< 400 ~= response.statusCode,
                  response.statusCode != 304 else { continue }
            NetworkLogRecorder.shared.addRedirect(to: log.token, from: response, request: next.request)
        }
    }

    private var session: URLSession {
        lock.withLock {
            if let sessionStorage {
                return sessionStorage
            }
            let session = sessionFactory(self)
            sessionStorage = session
            // Restored tasks have no awaiting continuation in this process,
            // but still represent real transfers and must be logged. Create
            // their tokens early so a subsequent clear invalidates them too.
            session.getAllTasks { [weak self] tasks in
                for task in tasks where task.state != .completed {
                    _ = self?.networkLog(for: task)
                }
            }
            return session
        }
    }

    private func currentCredentials() async -> YamiboRequestCredentials? {
        guard let sessionStore else { return nil }
        let session = await sessionStore.load()
        return session.credentials
    }

    private func register(
        taskIdentifier: Int,
        task: URLSessionTask,
        continuation: CheckedContinuation<Data, any Error>,
        progress: @escaping @Sendable (DownloadTransferProgress) -> Void,
        logToken: NetworkLogToken
    ) {
        lock.withLock {
            pendingDownloads[taskIdentifier] = PendingDownload(continuation: continuation, task: task, progress: progress)
            unstartedTaskIdentifiers.remove(taskIdentifier)
            networkLogs[taskIdentifier] = DownloadNetworkLog(token: logToken)
        }
    }

    private func networkLog(for task: URLSessionTask) -> DownloadNetworkLog? {
        lock.withLock {
            guard !unstartedTaskIdentifiers.contains(task.taskIdentifier) else { return nil }
            if let log = networkLogs[task.taskIdentifier] { return log }
            guard let request = task.originalRequest ?? task.currentRequest else { return nil }
            let log = DownloadNetworkLog(token: NetworkLogRecorder.shared.begin(request: request, source: .download))
            networkLogs[task.taskIdentifier] = log
            return log
        }
    }

    private func complete(taskIdentifier: Int, result: Result<Data, any Error>) {
        let pending = lock.withLock {
            pendingDownloads.removeValue(forKey: taskIdentifier)
        }
        guard let pending else { return }

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

import Foundation

public final class DownloadBackgroundTransport: NSObject, DownloadImageTransporting, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let defaultIdentifier = YamiboForumEnvironment.current.backgroundDownloadIdentifier

    private let lock = NSLock()
    private let sessionFactory: @Sendable (URLSessionDelegate) -> URLSession
    private var sessionStorage: URLSession?
    private var invalidationContinuation: CheckedContinuation<Void, Never>?
    private var pendingDownloads: [Int: PendingDownload] = [:]
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
                task.taskDescription = source.url.absoluteString
                let admitted = taskBox.admit(task) {
                    guard !Task.isCancelled else { return false }
                    register(
                        taskIdentifier: task.taskIdentifier,
                        task: task,
                        continuation: continuation
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
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
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
        completionHandler(YamiboNetworkPolicy.redirectedRequest(request, from: task.originalRequest?.url))
    }

    private var session: URLSession {
        lock.withLock {
            if let sessionStorage {
                return sessionStorage
            }
            let session = sessionFactory(self)
            sessionStorage = session
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
        continuation: CheckedContinuation<Data, any Error>
    ) {
        lock.withLock {
            pendingDownloads[taskIdentifier] = PendingDownload(continuation: continuation, task: task)
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

private struct PendingDownload {
    var continuation: CheckedContinuation<Data, any Error>
    var task: URLSessionTask?
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

import Foundation

public final class OfflineCacheBackgroundDownloadTransport: NSObject, OfflineCacheImageTransporting, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let defaultIdentifier = "com.arkalin.YamiboX.offlineCache.backgroundDownloads"

    private let lock = NSLock()
    private let sessionFactory: @Sendable (URLSessionDelegate) -> URLSession
    private var sessionStorage: URLSession?
    private var pendingDownloads: [Int: PendingDownload] = [:]
    private var backgroundEventCompletionHandlers: [String: () -> Void] = [:]

    public init(
        configuration: URLSessionConfiguration = OfflineCacheBackgroundDownloadTransport.makeBackgroundConfiguration(),
        delegateQueue: OperationQueue? = nil
    ) {
        let queue = delegateQueue ?? OperationQueue()
        queue.maxConcurrentOperationCount = 1
        sessionFactory = { delegate in
            URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        }
        super.init()
    }

    init(sessionFactory: @escaping @Sendable (URLSessionDelegate) -> URLSession) {
        self.sessionFactory = sessionFactory
        super.init()
    }

    public static func makeBackgroundConfiguration(
        identifier: String = defaultIdentifier
    ) -> URLSessionConfiguration {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #else
        let configuration = URLSessionConfiguration.default
        #endif
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.allowsCellularAccess = true
        return configuration
    }

    public func downloadImageData(for source: YamiboImageSource) async throws -> Data {
        let taskBox = URLSessionTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var urlRequest = URLRequest(url: source.url)
                if let refererPageURL = source.refererPageURL {
                    urlRequest.setValue(refererPageURL.absoluteString, forHTTPHeaderField: "Referer")
                }
                let task = session.downloadTask(with: urlRequest)
                task.taskDescription = source.url.absoluteString
                taskBox.setTask(task)
                register(
                    taskIdentifier: task.taskIdentifier,
                    task: task,
                    continuation: continuation
                )
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    public func cancelAllDownloads() {
        let tasks = lock.withLock { pendingDownloads.values.compactMap(\.task) }
        tasks.forEach { $0.cancel() }
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

    func setTask(_ task: URLSessionTask) {
        lock.withLock {
            self.task = task
        }
    }

    func cancel() {
        lock.withLock {
            task?.cancel()
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

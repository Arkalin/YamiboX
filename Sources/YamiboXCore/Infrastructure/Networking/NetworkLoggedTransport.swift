import Foundation

/// Observes individual URLSession attempts, below WAF recovery and business decoding.
enum NetworkLoggedTransport {
    static func data(
        for request: URLRequest,
        using session: URLSession,
        source: NetworkLogSource = .http,
        delegate: (any URLSessionTaskDelegate)? = nil,
        bodyPolicy: NetworkResponseBodyPolicy? = nil,
        recorder: NetworkLogRecorder = .shared
    ) async throws -> (Data, URLResponse) {
        let token = recorder.begin(request: request, source: source)
        let receiver = bodyPolicy.map(NetworkResponseBodyReceiver.init(policy:))
        let observer = AttemptDelegate(
            token: token,
            recorder: recorder,
            delegate: delegate,
            sessionDelegate: session.delegate as? any URLSessionTaskDelegate,
            receiver: receiver
        )
        if let receiver {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = session.dataTask(with: request)
                    task.delegate = observer
                    // Plain task creation precedes assigning the per-task delegate.
                    observer.urlSession(session, didCreateTask: task)
                    if !receiver.start(task, continuation: continuation) {
                        task.cancel()
                        observer.completeBody(error: CancellationError())
                    }
                }
            } onCancel: {
                receiver.cancel()
            }
        }
        do {
            let result = try await session.data(for: request, delegate: observer)
            observer.finish(response: result.1, receivedBytes: Int64(result.0.count), error: nil)
            return result
        } catch {
            observer.finish(response: nil, receivedBytes: nil, error: error)
            throw error
        }
    }

    private final class AttemptDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let token: NetworkLogToken
        private let recorder: NetworkLogRecorder
        private let delegate: (any URLSessionTaskDelegate)?
        private let sessionDelegate: (any URLSessionTaskDelegate)?
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var duration: TimeInterval?
        private let receiver: NetworkResponseBodyReceiver?

        init(
            token: NetworkLogToken,
            recorder: NetworkLogRecorder,
            delegate: (any URLSessionTaskDelegate)?,
            sessionDelegate: (any URLSessionTaskDelegate)?,
            receiver: NetworkResponseBodyReceiver?
        ) {
            self.token = token
            self.recorder = recorder
            self.delegate = delegate
            self.sessionDelegate = sessionDelegate
            self.receiver = receiver
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let created = lock.withLock {
                guard self.task !== task else { return false }
                self.task = task
                return true
            }
            guard created else { return }
            if let callback = delegate?.urlSession(_:didCreateTask:) {
                callback(session, task)
            } else {
                sessionDelegate?.urlSession?(session, didCreateTask: task)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            receiver?.receive(response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if receiver?.receive(data) == false { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            completeBody(error: error)
        }

        func completeBody(error: (any Error)?) {
            guard let completion = receiver?.complete(error: error) else { return }
            let failure: (any Error)?
            if case let .failure(error) = completion.result { failure = error } else { failure = nil }
            finish(response: completion.response, receivedBytes: completion.receivedBytes, error: failure)
            completion.continuation.resume(with: completion.result)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let completion: @Sendable (URLRequest?) -> Void = { [token, recorder, receiver] admitted in
                if let admitted {
                    recorder.addRedirect(to: token, from: response, request: admitted)
                } else {
                    // A denied redirect may complete without a data-delegate
                    // response callback. Preserve its explicit continuation URL.
                    receiver?.receive(response)
                }
                completionHandler(admitted)
            }
            if let callback = delegate?.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) {
                callback(session, task, response, request, completion)
            } else if let callback = sessionDelegate?.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) {
                callback(session, task, response, request, completion)
            } else {
                completion(request)
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let callback = delegate?.urlSession(_:task:didReceive:completionHandler:) {
                callback(session, task, challenge, completionHandler)
            } else if let callback = sessionDelegate?.urlSession(_:task:didReceive:completionHandler:) {
                callback(session, task, challenge, completionHandler)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            lock.withLock { duration = metrics.taskInterval.duration }
            if let callback = delegate?.urlSession(_:task:didFinishCollecting:) {
                callback(session, task, metrics)
            } else {
                sessionDelegate?.urlSession?(session, task: task, didFinishCollecting: metrics)
            }
        }

        func finish(response: URLResponse?, receivedBytes: Int64?, error: (any Error)?) {
            let (task, duration) = lock.withLock { (self.task, self.duration) }
            recorder.finish(
                token,
                response: response ?? task?.response,
                sentBytes: task?.countOfBytesSent,
                receivedBytes: task.map { max(0, $0.countOfBytesReceived) } ?? receivedBytes,
                error: error,
                finalURL: task?.currentRequest?.url,
                duration: duration
            )
            // The task retains its task delegate; don't retain it back past completion.
            lock.withLock { self.task = nil }
        }
    }
}

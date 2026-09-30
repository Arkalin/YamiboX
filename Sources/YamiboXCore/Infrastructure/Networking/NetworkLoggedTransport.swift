import Foundation

/// Observes individual URLSession attempts, below WAF recovery and business decoding.
enum NetworkLoggedTransport {
    static func data(
        for request: URLRequest,
        using session: URLSession,
        source: NetworkLogSource = .http,
        delegate: (any URLSessionTaskDelegate)? = nil,
        recorder: NetworkLogRecorder = .shared
    ) async throws -> (Data, URLResponse) {
        let token = recorder.begin(request: request, source: source)
        let observer = AttemptDelegate(
            token: token,
            recorder: recorder,
            delegate: delegate,
            sessionDelegate: session.delegate as? any URLSessionTaskDelegate
        )
        do {
            let result = try await session.data(for: request, delegate: observer)
            observer.finish(response: result.1, receivedBytes: Int64(result.0.count), error: nil)
            return result
        } catch {
            observer.finish(response: nil, receivedBytes: nil, error: error)
            throw error
        }
    }

    private final class AttemptDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let token: NetworkLogToken
        private let recorder: NetworkLogRecorder
        private let delegate: (any URLSessionTaskDelegate)?
        private let sessionDelegate: (any URLSessionTaskDelegate)?
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var duration: TimeInterval?

        init(
            token: NetworkLogToken,
            recorder: NetworkLogRecorder,
            delegate: (any URLSessionTaskDelegate)?,
            sessionDelegate: (any URLSessionTaskDelegate)?
        ) {
            self.token = token
            self.recorder = recorder
            self.delegate = delegate
            self.sessionDelegate = sessionDelegate
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            lock.withLock { self.task = task }
            if let callback = delegate?.urlSession(_:didCreateTask:) {
                callback(session, task)
            } else {
                sessionDelegate?.urlSession?(session, didCreateTask: task)
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let completion: @Sendable (URLRequest?) -> Void = { [token, recorder] admitted in
                if let admitted {
                    recorder.addRedirect(to: token, from: response, request: admitted)
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

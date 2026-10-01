import Foundation

struct NetworkResponseBodyLimit: Sendable {
    let maximumBytes: Int
    let error: any Error
}

/// Feature-owned classification after a small prefix. A nil limit preserves
/// the ordinary document/error-body contract rather than limiting all HTML.
struct NetworkResponseBodyPolicy: Sendable {
    let prefixByteCount: Int
    let classify: @Sendable (HTTPURLResponse, Data) -> NetworkResponseBodyLimit?
}

/// Plain data tasks deliver chunks here. Completion-handler/async data tasks
/// aggregate their body inside Foundation and cannot enforce this buffer cap.
final class NetworkResponseBodyReceiver: @unchecked Sendable {
    struct Completion {
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
        let result: Result<(Data, URLResponse), any Error>
        let response: URLResponse?
        let receivedBytes: Int64
    }

    private let lock = NSLock()
    private let policy: NetworkResponseBodyPolicy
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var body = Data()
    private var receivedBytes: Int64 = 0
    private var limit: NetworkResponseBodyLimit?
    private var classified = false
    private var failure: (any Error)?
    private var completed = false

    init(policy: NetworkResponseBodyPolicy) { self.policy = policy }

    /// Cancellation and start admission share one lock. A cancellation before
    /// credentials/continuation setup must not start a request afterwards.
    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, URLResponse), any Error>) -> Bool {
        lock.withLock {
            self.task = task
            self.continuation = continuation
            guard failure == nil else { return false }
            task.resume()
            return true
        }
    }

    func cancel() {
        let task = lock.withLock {
            if failure == nil { failure = CancellationError() }
            return self.task
        }
        task?.cancel()
    }

    func receive(_ response: URLResponse) {
        lock.withLock { self.response = response }
    }

    /// Never append an oversized chunk into the retained body. Transport may
    /// already have delivered that one chunk; cancelling stops subsequent work.
    func receive(_ data: Data) -> Bool {
        lock.withLock {
            guard !completed, failure == nil else { return false }
            receivedBytes += Int64(data.count)
            var consumed = 0
            if !classified {
                consumed = min(data.count, max(0, policy.prefixByteCount - body.count))
                body.append(data.prefix(consumed))
                if body.count >= policy.prefixByteCount { classify() }
            }
            if let limit, body.count > limit.maximumBytes
                || data.count - consumed > max(0, limit.maximumBytes - body.count) {
                failure = limit.error
                body.removeAll(keepingCapacity: false)
                return false
            }
            body.append(data.dropFirst(consumed))
            return true
        }
    }

    func complete(error: (any Error)?) -> Completion? {
        lock.withLock {
            guard !completed, let continuation else { return nil }
            completed = true
            if !classified { classify() }
            if failure == nil, let limit, body.count > limit.maximumBytes { failure = limit.error }
            let result: Result<(Data, URLResponse), any Error>
            if let error = failure ?? error { result = .failure(error) }
            else if let response { result = .success((body, response)) }
            else { result = .failure(YamiboError.invalidResponse(statusCode: nil)) }
            let completion = Completion(continuation: continuation, result: result, response: response, receivedBytes: receivedBytes)
            self.continuation = nil
            task = nil
            body = Data()
            return completion
        }
    }

    private func classify() {
        classified = true
        if let response = response as? HTTPURLResponse {
            limit = policy.classify(response, body)
        }
    }
}

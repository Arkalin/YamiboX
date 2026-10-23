import Foundation

/// A single data attempt. Business delegates retain their stricter redirect
/// policy and progress observation; they cannot relax this origin boundary.
enum ForumDataTransport {
    static func data(
        request: URLRequest,
        attempt: ForumRequestAttempt,
        session: URLSession,
        delegate: (any URLSessionTaskDelegate)?,
        bodyPolicy: NetworkResponseBodyPolicy?,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> YamiboHTTPResponse {
        guard let url = request.url, attempt.context.key.origin.contains(url) else {
            throw YamiboError.invalidResponse(statusCode: nil)
        }
        let observer = RedirectObserver(request: request, attempt: attempt, downstream: delegate)
        let policy = NetworkResponseBodyPolicy(prefixByteCount: ForumWAFResponseClassifier.maximumBodyBytes) { response, prefix in
            if let failure = observer.challenge(response: response, prefix: prefix) {
                return NetworkResponseBodyLimit(maximumBytes: 0, error: failure)
            }
            if response.statusCode == 405 {
                return NetworkResponseBodyLimit(maximumBytes: ForumWAFResponseClassifier.maximumBodyBytes,
                                                error: YamiboError.invalidResponse(statusCode: 405))
            }
            return bodyPolicy?.classify(response, Data(prefix.prefix(bodyPolicy?.prefixByteCount ?? 0)))
        } headerFailure: { response in
            observer.challenge(response: response, prefix: Data())
        }
        do {
            let (data, response) = try await NetworkLoggedTransport.data(
                for: request, using: session, delegate: observer, bodyPolicy: policy, progress: progress
            )
            if let challenge = observer.redirectChallenge { throw challenge }
            guard let response = response as? HTTPURLResponse else { throw YamiboError.invalidResponse(statusCode: nil) }
            if let challenge = observer.challenge(response: response, prefix: data) { throw challenge }
            return YamiboHTTPResponse(data: data, response: response)
        } catch {
            if let challenge = observer.redirectChallenge { throw challenge }
            throw error
        }
    }

    private final class RedirectObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let request: URLRequest
        private let attempt: ForumRequestAttempt
        private let downstream: (any URLSessionTaskDelegate)?
        private let lock = NSLock()
        private var evidence: ForumRedirectEvidence

        init(request: URLRequest, attempt: ForumRequestAttempt, downstream: (any URLSessionTaskDelegate)?) {
            self.request = request
            self.attempt = attempt
            self.downstream = downstream
            evidence = ForumRedirectEvidence(origin: attempt.context.key.origin, originalURL: request.url!)
        }

        var redirectChallenge: ForumTransportChallenge? {
            lock.withLock { evidence.challengeURL.map { makeChallenge(url: $0) } }
        }

        func challenge(response: HTTPURLResponse, prefix: Data) -> ForumTransportChallenge? {
            lock.withLock {
                guard ForumWAFResponseClassifier.matches(response: response, prefix: prefix,
                    origin: evidence.origin, originalURL: evidence.originalURL, leftOrigin: evidence.leftOrigin),
                    let url = response.url else { return nil }
                return makeChallenge(url: url)
            }
        }

        private func makeChallenge(url: URL) -> ForumTransportChallenge {
            ForumTransportChallenge(challenge: ForumWAFResponseClassifier.challenge(url: url, request: request, credentials: attempt.credentials))
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            downstream?.urlSession?(session, didCreateTask: task)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let from = response.url, let to = request.url else { completionHandler(nil); return }
            let admitted = lock.withLock {
                evidence.observe(from: from, to: to)
                return evidence.challengeURL == nil && !evidence.leftOrigin && evidence.count <= 10
            }
            guard admitted else { completionHandler(nil); return }
            let completion: @Sendable (URLRequest?) -> Void = { [attempt] proposed in
                guard var proposed, let url = proposed.url, attempt.context.key.origin.contains(url) else {
                    completionHandler(nil)
                    return
                }
                // Foundation may discard a manually supplied header on redirect.
                // Rebuild it from the immutable attempt, never the current account.
                YamiboNetworkPolicy.applyCredentials(attempt.credentials, to: &proposed,
                    handlesCookies: self.request.httpShouldHandleCookies,
                    cookieStorageContext: self.request.httpShouldHandleCookies ? .isolatedLogin : .standard)
                completionHandler(proposed)
            }
            if let callback = downstream?.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:) {
                callback(session, task, response, request, completion)
            } else {
                completion(request)
            }
        }
    }
}

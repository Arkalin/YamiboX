import Foundation
import Nuke

public protocol YamiboOrdinaryImageCacheClearing: Sendable {
    func removeAllCachedData() async
    func totalDiskUsageBytes() async -> Int
}

/// `@unchecked Sendable`: holds only immutable references to internally
/// thread-safe Nuke objects.
final class YamiboImageDataPipeline: YamiboOrdinaryImageCacheClearing, @unchecked Sendable {
    static let defaultDataCacheLimitBytes = 512 * 1024 * 1024
    static let defaultDataCacheName = "com.arkalin.YamiboX.OrdinaryImageDataCache"

    private let pipeline: ImagePipeline
    private let dataCache: DataCache?

    var hasDataCache: Bool { dataCache != nil }

    var dataCacheLimitBytes: Int {
        dataCache?.sizeLimit ?? 0
    }

    var usesURLCacheDiskStorage: Bool {
        false
    }

    convenience init(
        dataCacheName: String = YamiboImageDataPipeline.defaultDataCacheName,
        dataCacheLimitBytes: Int = YamiboImageDataPipeline.defaultDataCacheLimitBytes
    ) {
        self.init(dataCacheLimitBytes: dataCacheLimitBytes) {
            try DataCache(name: dataCacheName)
        }
    }

    convenience init(
        dataCacheDirectory: URL,
        dataCacheLimitBytes: Int = YamiboImageDataPipeline.defaultDataCacheLimitBytes
    ) {
        self.init(dataCacheLimitBytes: dataCacheLimitBytes) {
            try DataCache(path: dataCacheDirectory)
        }
    }

    private init(
        dataCacheLimitBytes: Int,
        makeDataCache: () throws -> DataCache
    ) {
        let dataCache: DataCache?
        do {
            dataCache = try makeDataCache()
        } catch {
            // Regenerable image bytes must not prevent the app from launching.
            YamiboLog.persistence.error("Image disk cache unavailable; continuing without disk caching: \(error)")
            dataCache = nil
        }
        // Disable the startup sweep before constructing the network loader.
        dataCache?.isSweepEnabled = false
        dataCache?.sizeLimit = dataCacheLimitBytes
        self.dataCache = dataCache

        var configuration = ImagePipeline.Configuration(dataLoader: MissingImageAttemptLoader())
        configuration.dataCache = dataCache.map { YamiboMaintainedImageDataCache(cache: $0) }
        configuration.dataCachePolicy = .storeOriginalData
        configuration.isResumableDataEnabled = true
        // Nuke's original-data key ignores Cookie/Referer. Core single-flight
        // now owns coalescing using the actual request context instead.
        configuration.isTaskCoalescingEnabled = false
        self.pipeline = ImagePipeline(
            configuration: configuration,
            delegate: YamiboImageDataPipelineDelegate()
        )
    }

    func data(
        for source: YamiboImageSource,
        attempt: ForumRequestAttempt,
        session: URLSession
    ) async throws -> Data {
        do {
            let (data, _) = try await pipeline.data(for: nukeRequest(for: source, attempt: attempt, session: session))
            return data
        } catch {
            throw LoadDiagnosticError.attaching(to: Self.mapImagePipelineError(error), requestContext: source.url.absoluteString)
        }
    }

    func cachedData(for source: YamiboImageSource) -> Data? {
        // Explicit lookup also permits promoting existing reader bytes for a
        // cover. Cover network requests themselves never use this disk cache.
        dataCache?.cachedData(for: source.cacheKey)
    }

    func removeCachedData(for source: YamiboImageSource) {
        pipeline.cache.removeCachedData(for: nukeRequest(for: source))
    }

    func storeOrdinaryImageData(_ data: Data, for source: YamiboImageSource) {
        guard source.purpose == .content, dataCache?.containsData(for: source.cacheKey) == false else { return }
        pipeline.cache.storeCachedData(data, for: nukeRequest(for: source))
    }

    func removeAllCachedData() async {
        pipeline.cache.removeAll()
    }

    func totalDiskUsageBytes() async -> Int {
        guard let dataCache else { return 0 }
        // Nuke stages writes and deletions. Flush off-main before measuring so
        // a refresh immediately after clearing cannot report the old files.
        return await Task.detached(priority: .utility) { [dataCache] in
            dataCache.flush()
            return dataCache.queue.sync { dataCache.totalAllocatedSize }
        }.value
    }

    private func nukeRequest(
        for source: YamiboImageSource,
        attempt: ForumRequestAttempt? = nil,
        session: URLSession? = nil
    ) -> ImageRequest {
        var urlRequest = YamiboNetworkConfiguration.makeRequest(
            url: source.url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        urlRequest.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        var userInfo: [ImageRequest.UserInfoKey: any Sendable] = [:]
        if let attempt, let session {
            YamiboNetworkPolicy.applyCredentials(attempt.credentials, to: &urlRequest, handlesCookies: false)
            userInfo[.yamiboURLSession] = YamiboImageRequestSession(session, attempt: attempt)
        }
        if let refererPageURL = source.refererPageURL {
            urlRequest.setValue(refererPageURL.absoluteString, forHTTPHeaderField: "Referer")
        }

        var imageRequest = ImageRequest(urlRequest: urlRequest, userInfo: userInfo)
        imageRequest.imageID = source.cacheKey
        if source.purpose == .cover { imageRequest.options.insert(.disableDiskCache) }
        return imageRequest
    }

    private static func mapImagePipelineError(_ error: ImagePipeline.Error) -> Error {
        switch error {
        case .dataLoadingFailed(let underlying):
            return mapUnderlyingError(underlying)
        case .dataIsEmpty:
            return LoadDiagnosticError.mapping(error, to: YamiboError.unreadableBody)
        case .cancelled:
            return CancellationError()
        default:
            return LoadDiagnosticError.mapping(error, to: YamiboError.underlying(error.localizedDescription))
        }
    }

    private static func mapUnderlyingError(_ error: Error) -> Error {
        if error is LoadDiagnosticError || LoadDiagnosticError.isCancellation(error) { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return LoadDiagnosticError.mapping(error, to: YamiboError.offline)
            default:
                return LoadDiagnosticError.mapping(error, to: YamiboError.underlying(urlError.localizedDescription))
            }
        }
        // Only transport errors need translation here. Preserve other errors
        // without making the image pipeline recognize each feature's types.
        return error
    }
}

private final class YamiboImageDataPipelineDelegate: ImagePipeline.Delegate {
    func dataLoader(for request: ImageRequest, pipeline: ImagePipeline) -> any DataLoading {
        if let session = request.userInfo[.yamiboURLSession] as? YamiboImageRequestSession {
            return YamiboURLSessionImageDataLoader(session: session.value, attempt: session.attempt)
        }
        return pipeline.configuration.dataLoader
    }
}

private struct YamiboImageRequestSession: @unchecked Sendable {
    let value: URLSession
    let attempt: ForumRequestAttempt

    init(_ value: URLSession, attempt: ForumRequestAttempt) {
        self.value = value
        self.attempt = attempt
    }
}

final class YamiboURLSessionImageDataLoader: DataLoading, @unchecked Sendable {
    private let session: URLSession
    private let attempt: ForumRequestAttempt

    init(session: URLSession, attempt: ForumRequestAttempt) {
        self.session = session
        self.attempt = attempt
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let task = session.dataTask(with: request)
        // Chunked delegate delivery (instead of one-shot `data(for:)`) is what
        // lets Nuke accumulate the partial data required for resumable
        // downloads; the task retains its delegate until it completes.
        task.delegate = StreamingDeliveryHandler(
            request: request, attempt: attempt,
            logToken: NetworkLogRecorder.shared.begin(request: request, source: .image),
            didReceiveData: didReceiveData,
            completion: completion
        )
        task.resume()
        return YamiboDataTaskCancellable(task: task)
    }

    private static func validationError(for response: URLResponse) -> Error? {
        guard let httpResponse = response as? HTTPURLResponse else {
            return YamiboError.invalidResponse(statusCode: nil)
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 401 {
                return YamiboError.notAuthenticated
            }
            return YamiboError.invalidResponse(statusCode: httpResponse.statusCode)
        }
        return nil
    }

    private static func mapNetworkError(_ error: Error) -> Error {
        if LoadDiagnosticError.isCancellation(error) { return error }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return LoadDiagnosticError.mapping(error, to: YamiboError.offline)
            default:
                return LoadDiagnosticError.mapping(error, to: YamiboError.underlying(urlError.localizedDescription))
            }
        }
        return error
    }

    private final class StreamingDeliveryHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let logToken: NetworkLogToken
        private let didReceiveData: @Sendable (Data, URLResponse) -> Void
        private let completion: @Sendable (Error?) -> Void
        // URLSession delivers a task's delegate callbacks serially; these are
        // only touched from that serial context.
        private var validatedResponse: URLResponse?
        private var validationError: Error?
        private var duration: TimeInterval?
        private let request: URLRequest
        private let attempt: ForumRequestAttempt
        private var evidence: ForumRedirectEvidence
        private var challengeResponse: HTTPURLResponse?
        private var challengeBody = Data()
        private static let maximumChallengeBodyBytes = 128 * 1024

        init(
            request: URLRequest, attempt: ForumRequestAttempt,
            logToken: NetworkLogToken,
            didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
            completion: @escaping @Sendable (Error?) -> Void
        ) {
            self.logToken = logToken
            self.request = request
            self.attempt = attempt
            evidence = ForumRedirectEvidence(origin: attempt.context.key.origin, originalURL: request.url!)
            self.didReceiveData = didReceiveData
            self.completion = completion
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            // A redirect rejected as a challenge can still deliver its 302
            // response here. Do not overwrite that error with a generic one.
            guard validationError == nil else {
                completionHandler(.cancel)
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               let responseURL = httpResponse.url,
               httpResponse.statusCode == 405, canRecover(httpResponse, task: dataTask) {
                if ForumWAFResponseClassifier.matches(response: httpResponse, prefix: Data(),
                    origin: evidence.origin, originalURL: evidence.originalURL, leftOrigin: evidence.leftOrigin) {
                    validationError = verificationError(for: httpResponse)
                    completionHandler(.cancel)
                } else {
                    // Some gateways identify a challenge only in its HTML.
                    // Inspect a bounded prefix without passing it to Nuke/cache.
                    challengeResponse = httpResponse
                    completionHandler(.allow)
                }
                return
            }
            if let error = YamiboURLSessionImageDataLoader.validationError(for: response) {
                validationError = LoadDiagnosticError.attaching(to: error, requestContext: response.url?.absoluteString, httpStatus: (response as? HTTPURLResponse)?.statusCode)
                completionHandler(.cancel)
                return
            }
            validatedResponse = response
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let from = response.url, let to = request.url else { completionHandler(nil); return }
            evidence.observe(from: from, to: to)
            if evidence.challengeURL != nil {
                validationError = verificationError(for: response)
                completionHandler(nil)
                return
            }
            guard evidence.count <= 10,
                  !evidence.origin.contains(evidence.originalURL) || !evidence.leftOrigin else {
                validationError = YamiboError.invalidResponse(statusCode: response.statusCode)
                completionHandler(nil)
                return
            }
            var redirected = request
            if evidence.origin.contains(evidence.originalURL), !evidence.leftOrigin {
                YamiboNetworkPolicy.applyCredentials(attempt.credentials, to: &redirected, handlesCookies: false)
            } else {
                redirected.setValue(nil, forHTTPHeaderField: "Cookie")
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
                redirected.setValue(nil, forHTTPHeaderField: "Referer")
                redirected.httpShouldHandleCookies = false
            }
            NetworkLogRecorder.shared.addRedirect(to: logToken, from: response, request: redirected)
            completionHandler(redirected)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if let challengeResponse {
                challengeBody.append(data.prefix(Self.maximumChallengeBodyBytes - challengeBody.count))
                if challengeBody.count == Self.maximumChallengeBodyBytes {
                    validationError = challengeResponseError(challengeResponse)
                    dataTask.cancel()
                }
                return
            }
            guard let validatedResponse else { return }
            didReceiveData(data, validatedResponse)
        }

        private func canRecover(_ response: HTTPURLResponse, task: URLSessionTask) -> Bool {
            guard !evidence.leftOrigin, let original = task.originalRequest?.url, let final = response.url,
                  original.user == nil, original.password == nil, final.user == nil, final.password == nil else { return false }
            return YamiboImageSource.sameOrigin(original, YamiboDomain.baseURL)
                && YamiboImageSource.sameOrigin(final, YamiboDomain.baseURL)
        }

        private func verificationError(for response: HTTPURLResponse) -> any Error {
            guard let url = response.url else { return YamiboError.invalidResponse(statusCode: response.statusCode) }
            return ForumTransportChallenge(challenge: ForumWAFResponseClassifier.challenge(
                url: url, request: request, credentials: attempt.credentials))
        }

        private func challengeResponseError(_ response: HTTPURLResponse) -> any Error {
            if let url = response.url, ForumWAFResponseClassifier.matches(response: response, prefix: challengeBody,
                origin: evidence.origin, originalURL: evidence.originalURL, leftOrigin: evidence.leftOrigin) {
                return verificationError(for: response)
            }
            return LoadDiagnosticError.attaching(to: YamiboError.invalidResponse(statusCode: response.statusCode),
                requestContext: response.url?.absoluteString, httpStatus: response.statusCode)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            duration = metrics.taskInterval.duration
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if validationError == nil, error == nil, let challengeResponse {
                validationError = challengeResponseError(challengeResponse)
            }
            NetworkLogRecorder.shared.finish(
                logToken,
                response: task.response,
                sentBytes: task.countOfBytesSent,
                receivedBytes: task.countOfBytesReceived,
                error: validationError ?? error,
                finalURL: task.currentRequest?.url,
                duration: duration
            )
            if let validationError {
                completion(validationError)
                return
            }
            guard let error else {
                completion(nil)
                return
            }
            completion(YamiboURLSessionImageDataLoader.mapNetworkError(error))
        }
    }
}

/// Cache-only Nuke requests may omit an attempt, but must never reach the network.
private final class MissingImageAttemptLoader: DataLoading, @unchecked Sendable {
    func loadData(with request: URLRequest,
                  didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        completion(ForumWAFFailure.runtimeUnavailable)
        return EmptyImageCancellation()
    }
}

private struct EmptyImageCancellation: Cancellable {
    func cancel() {}
}

private final class YamiboDataTaskCancellable: Cancellable, @unchecked Sendable {
    private let task: URLSessionDataTask

    init(task: URLSessionDataTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

private extension ImageRequest.UserInfoKey {
    static let yamiboURLSession = ImageRequest.UserInfoKey("com.arkalin.YamiboX.urlSession")
}

import Foundation
import Nuke

public protocol YamiboOrdinaryImageCacheClearing: Sendable {
    func removeAllCachedData() async
}

/// `@unchecked Sendable`: holds no mutable state of its own — both stored
/// properties are immutable references to Nuke's `ImagePipeline`/`DataCache`,
/// which are internally thread-safe. Keep any future state behind a lock or
/// this annotation becomes a lie.
final class YamiboImageDataPipeline: YamiboOrdinaryImageCacheClearing, @unchecked Sendable {
    static let shared = YamiboImageDataPipeline()
    static let defaultDataCacheLimitBytes = 512 * 1024 * 1024
    static let defaultDataCacheName = "com.arkalin.YamiboX.OrdinaryImageDataCache"

    private let pipeline: ImagePipeline
    private let dataCache: DataCache

    var dataCacheLimitBytes: Int {
        dataCache.sizeLimit
    }

    var usesURLCacheDiskStorage: Bool {
        false
    }

    convenience init(
        dataCacheName: String = YamiboImageDataPipeline.defaultDataCacheName,
        dataCacheLimitBytes: Int = YamiboImageDataPipeline.defaultDataCacheLimitBytes
    ) {
        let dataCache: DataCache
        do {
            dataCache = try DataCache(name: dataCacheName)
        } catch {
            fatalError("Failed to create Yamibo Nuke image DataCache: \(error)")
        }
        self.init(dataCache: dataCache, dataCacheLimitBytes: dataCacheLimitBytes)
    }

    convenience init(
        dataCacheDirectory: URL,
        dataCacheLimitBytes: Int = YamiboImageDataPipeline.defaultDataCacheLimitBytes
    ) throws {
        try self.init(
            dataCache: DataCache(path: dataCacheDirectory),
            dataCacheLimitBytes: dataCacheLimitBytes
        )
    }

    private init(dataCache: DataCache, dataCacheLimitBytes: Int) {
        dataCache.sizeLimit = dataCacheLimitBytes
        self.dataCache = dataCache

        let fallbackLoader = DataLoader(configuration: YamiboNetworkConfiguration.makeImageSessionConfiguration())
        var configuration = ImagePipeline.Configuration(dataLoader: fallbackLoader)
        configuration.dataCache = dataCache
        configuration.dataCachePolicy = .storeOriginalData
        configuration.isResumableDataEnabled = true
        self.pipeline = ImagePipeline(
            configuration: configuration,
            delegate: YamiboImageDataPipelineDelegate()
        )
    }

    func data(
        for source: YamiboImageSource,
        client: YamiboClient
    ) async throws -> Data {
        do {
            let (data, _) = try await pipeline.data(for: nukeRequest(for: source, client: client))
            return data
        } catch {
            throw Self.mapImagePipelineError(error)
        }
    }

    func cachedData(for source: YamiboImageSource) -> Data? {
        pipeline.cache.cachedData(for: nukeRequest(for: source, client: nil))
    }

    func removeAllCachedData() {
        pipeline.cache.removeAll()
    }

    private func nukeRequest(
        for source: YamiboImageSource,
        client: YamiboClient?
    ) -> ImageRequest {
        var urlRequest = YamiboNetworkConfiguration.makeRequest(
            url: source.url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        urlRequest.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        var userInfo: [ImageRequest.UserInfoKey: any Sendable] = [:]
        if let client {
            urlRequest.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
            if let cookie = client.cookie?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cookie.isEmpty {
                urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            userInfo[.yamiboURLSession] = YamiboImageRequestSession(client.session)
        }
        if let refererPageURL = source.refererPageURL {
            urlRequest.setValue(refererPageURL.absoluteString, forHTTPHeaderField: "Referer")
        }

        var imageRequest = ImageRequest(urlRequest: urlRequest, userInfo: userInfo)
        imageRequest.imageID = source.cacheKey
        return imageRequest
    }

    private static func mapImagePipelineError(_ error: ImagePipeline.Error) -> Error {
        switch error {
        case .dataLoadingFailed(let underlying):
            return mapUnderlyingError(underlying)
        case .dataIsEmpty:
            return YamiboError.unreadableBody
        case .cancelled:
            return CancellationError()
        default:
            return YamiboError.underlying(error.localizedDescription)
        }
    }

    private static func mapUnderlyingError(_ error: Error) -> Error {
        if let yamiboError = error as? YamiboError {
            return yamiboError
        }
        // Favorite-action and persistence errors were `YamiboError` cases
        // before the domain split and thus passed through the branch above
        // unchanged; keep that destination so they are never re-wrapped into
        // an `.underlying` string here.
        if error is FavoriteActionError || error is YamiboPersistenceError {
            return error
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return YamiboError.offline
            default:
                return YamiboError.underlying(urlError.localizedDescription)
            }
        }
        return YamiboError.underlying(error.localizedDescription)
    }
}

private final class YamiboImageDataPipelineDelegate: ImagePipeline.Delegate {
    func dataLoader(for request: ImageRequest, pipeline: ImagePipeline) -> any DataLoading {
        if let session = request.userInfo[.yamiboURLSession] as? YamiboImageRequestSession {
            return YamiboURLSessionImageDataLoader(session: session.value)
        }
        return pipeline.configuration.dataLoader
    }
}

private struct YamiboImageRequestSession: @unchecked Sendable {
    let value: URLSession

    init(_ value: URLSession) {
        self.value = value
    }
}

final class YamiboURLSessionImageDataLoader: DataLoading, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
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
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return YamiboError.notAuthenticated
            }
            return YamiboError.invalidResponse(statusCode: httpResponse.statusCode)
        }
        return nil
    }

    private static func mapNetworkError(_ error: Error) -> Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return YamiboError.offline
            default:
                return YamiboError.underlying(urlError.localizedDescription)
            }
        }
        return error
    }

    private final class StreamingDeliveryHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let didReceiveData: @Sendable (Data, URLResponse) -> Void
        private let completion: @Sendable (Error?) -> Void
        // URLSession delivers a task's delegate callbacks serially; these are
        // only touched from that serial context.
        private var validatedResponse: URLResponse?
        private var validationError: Error?

        init(
            didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
            completion: @escaping @Sendable (Error?) -> Void
        ) {
            self.didReceiveData = didReceiveData
            self.completion = completion
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            if let error = YamiboURLSessionImageDataLoader.validationError(for: response) {
                validationError = error
                completionHandler(.cancel)
                return
            }
            validatedResponse = response
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let validatedResponse else { return }
            didReceiveData(data, validatedResponse)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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

import Foundation

public enum YamiboNetworkConfiguration {
    public static let requestTimeout: TimeInterval = 15
    public static let resourceTimeout: TimeInterval = 15
    public static let defaultMobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    public static let desktopTagUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    public static func makeSession() -> URLSession {
        URLSession(configuration: makeSessionConfiguration())
    }

    public static func makeImageSession() -> URLSession {
        URLSession(configuration: makeImageSessionConfiguration())
    }

    public static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    public static func makeImageSessionConfiguration() -> URLSessionConfiguration {
        let configuration = makeSessionConfiguration()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    public static func makeRequest(
        url: URL,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) -> URLRequest {
        URLRequest(
            url: url,
            cachePolicy: cachePolicy,
            timeoutInterval: requestTimeout
        )
    }
}

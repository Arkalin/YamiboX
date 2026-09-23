import Foundation

/// The build selects the environment; test builds require a URL on every launch.
public enum YamiboForumEnvironment: Sendable, Equatable {
    case production
    case localSimulator(baseURL: URL)

    public static let launchConfiguration: Result<Self, YamiboForumConfigurationError> = {
        #if targetEnvironment(simulator)
        if Bundle.main.object(forInfoDictionaryKey: "YamiboForumEnvironment") as? String == "localSimulator" {
            return YamiboForumLaunchArguments.resolve(ProcessInfo.processInfo.arguments)
        }
        #endif
        return .success(.production)
    }()

    /// Only access after the composition root has accepted launchConfiguration.
    public static var current: Self {
        switch launchConfiguration {
        case let .success(environment): return environment
        case .failure: preconditionFailure("Forum dependencies require a valid launch configuration")
        }
    }

    public var baseURL: URL {
        switch self {
        case .production: URL(string: "https://bbs.yamibo.com")!
        case let .localSimulator(baseURL): baseURL
        }
    }

    public var rootDomain: String {
        switch self {
        case .production: "yamibo.com"
        case .localSimulator: forumHost
        }
    }

    public var forumHost: String { Self.normalizedHost(baseURL.host!) }

    public var requiresTestSitePreparation: Bool {
        if case .localSimulator = self { return true }
        return false
    }
    public var supportsBackgroundRelaunch: Bool { !requiresTestSitePreparation }
    var restrictsRequestsToForumOrigin: Bool { requiresTestSitePreparation }
    var legacyCookieIsSecure: Bool { baseURL.scheme == "https" }

    var accountKeychainService: String {
        switch self {
        case .production: "com.arkalin.YamiboX.accounts"
        case .localSimulator: "com.arkalin.YamiboX.local.accounts"
        }
    }

    var backgroundDownloadIdentifier: String {
        switch self {
        case .production: "com.arkalin.YamiboX.offlineCache.backgroundDownloads"
        case .localSimulator: "com.arkalin.YamiboX.local.offlineCache.backgroundDownloads"
        }
    }

    static let productionAuthenticationCookieName = "EeqY_2132_auth"

    public func isAuthenticationCookieName(_ name: String) -> Bool {
        switch self {
        case .production:
            return name == Self.productionAuthenticationCookieName
        case .localSimulator:
            let suffix = "_2132_auth"
            return name.hasSuffix(suffix) && name.count > suffix.count
        }
    }

    public func isForumURL(_ url: URL) -> Bool {
        guard url.host.map(Self.normalizedHost) == forumHost else { return false }
        return !restrictsRequestsToForumOrigin ||
            (url.scheme?.lowercased() == baseURL.scheme && Self.effectivePort(url) == Self.effectivePort(baseURL))
    }

    public func isSiteURL(_ url: URL) -> Bool {
        if restrictsRequestsToForumOrigin { return isForumURL(url) }
        guard let host = url.host?.lowercased() else { return false }
        return host == forumHost || host.hasSuffix(".\(rootDomain)")
    }

    public func isCookieDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased()
        if restrictsRequestsToForumOrigin {
            let domain = Self.normalizedHost(normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            return !domain.isEmpty && (forumHost == domain || forumHost.hasSuffix(".\(domain)"))
        }
        return normalized == rootDomain || normalized == forumHost || normalized.hasSuffix(".\(rootDomain)")
    }

    public func matchesCookieCleanupDomain(_ value: String) -> Bool {
        if restrictsRequestsToForumOrigin {
            return isCookieDomain(value)
        }
        return value.lowercased().contains(rootDomain)
    }

    func isForumPageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil, isForumURL(url) else { return false }
        return restrictsRequestsToForumOrigin || url.port == nil || url.port == 80 || url.port == 443
    }

    func normalizedForumPageURL(_ url: URL) -> URL {
        guard isForumPageURL(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.scheme = baseURL.scheme
        if !restrictsRequestsToForumOrigin, components.port == 80 { components.port = nil }
        return components.url ?? url
    }

    func allowsThreadResolution(_ url: URL) -> Bool {
        !restrictsRequestsToForumOrigin || isForumURL(url)
    }

    func adaptedResourceURL(_ url: URL, purpose: YamiboResourceURLPurpose) -> URL {
        if requiresTestSitePreparation, let adapted = YamiboLocalForumAdapter.resourceURL(url, baseURL: baseURL, purpose: purpose) {
            return adapted
        }
        // Preserve the existing profile-image cache-query normalization.
        if purpose == .profileImage, let query = url.absoluteString.firstIndex(of: "?") {
            return URL(string: String(url.absoluteString[..<query])) ?? url
        }
        return url
    }

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

enum YamiboResourceURLPurpose {
    case general
    case profileImage
}

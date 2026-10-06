import Foundation

public struct YamiboImageOfflineScope: Hashable, Sendable {
    public var tid: String
    public var ownerName: String?

    public init?(tid: String?, ownerName: String? = nil) {
        guard let tid = tid?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tid.isEmpty else {
            return nil
        }
        self.tid = tid
        let ownerName = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ownerName = (ownerName?.isEmpty ?? true) ? nil : ownerName
    }
}

public struct YamiboImageSource: Hashable, Sendable {
    public enum Purpose: Hashable, Sendable {
        case content
        case cover
    }

    public var url: URL
    public var refererPageURL: URL?
    public var offlineScope: YamiboImageOfflineScope?
    public var purpose: Purpose

    public init(
        url: URL,
        refererPageURL: URL? = nil,
        offlineScope: YamiboImageOfflineScope? = nil,
        purpose: Purpose = .content
    ) {
        self.url = url
        self.refererPageURL = refererPageURL
        self.offlineScope = offlineScope
        self.purpose = purpose
    }

    public var cacheKey: String {
        url.absoluteString
    }

    /// Unknown legacy manga provenance gets a site-level Referer, never an
    /// invented chapter. External artwork must not receive forum navigation.
    public static func cover(url: URL, refererPageURL: URL? = nil, threadID: String? = nil) -> Self {
        let fallback = YamiboDomain.isForumURL(url)
            ? threadID.map { YamiboRoute.threadByID(tid: $0, page: 1, authorID: nil, reverse: false).url }
                ?? YamiboDomain.baseURL
            : nil
        return Self(url: url, refererPageURL: sanitizedCoverReferer(refererPageURL, imageURL: url) ?? fallback,
            offlineScope: YamiboImageOfflineScope(tid: threadID), purpose: .cover)
    }

    public static func sanitizedCoverReferer(_ url: URL?, imageURL: URL) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if YamiboDomain.isForumURL(imageURL) {
            guard YamiboDomain.isForumURL(url) else { return nil }
        } else {
            guard !YamiboDomain.isForumURL(url), sameOrigin(url, imageURL) else { return nil }
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        let pageParameters: Set<String> = ["mod", "tid", "pid", "ptid", "page", "authorid", "ordertype", "mobile", "goto"]
        components.queryItems = components.queryItems?.filter { pageParameters.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    var normalizedForLoading: Self {
        guard purpose == .cover else { return self }
        var source = Self.cover(url: url, refererPageURL: refererPageURL)
        source.offlineScope = offlineScope
        return source
    }
}

public protocol YamiboOfflineImageDataProviding: Sendable {
    func offlineImageData(url: URL, scope: YamiboImageOfflineScope) async -> Data?
}

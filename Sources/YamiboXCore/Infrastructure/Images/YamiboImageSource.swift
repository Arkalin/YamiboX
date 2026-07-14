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
    public var url: URL
    public var refererPageURL: URL?
    public var offlineScope: YamiboImageOfflineScope?

    public init(
        url: URL,
        refererPageURL: URL? = nil,
        offlineScope: YamiboImageOfflineScope? = nil
    ) {
        self.url = url
        self.refererPageURL = refererPageURL
        self.offlineScope = offlineScope
    }

    public var cacheKey: String {
        url.absoluteString
    }
}

public protocol YamiboOfflineImageDataProviding: Sendable {
    func offlineImageData(url: URL, scope: YamiboImageOfflineScope) async -> Data?
}

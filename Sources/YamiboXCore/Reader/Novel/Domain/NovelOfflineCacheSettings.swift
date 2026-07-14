import Foundation

public struct NovelOfflineCacheSettings: Codable, Hashable, Sendable {
    public var retainsInlineImages: Bool
    public var isAutoRefreshEnabled: Bool

    public init(
        retainsInlineImages: Bool = false,
        isAutoRefreshEnabled: Bool = true
    ) {
        self.retainsInlineImages = retainsInlineImages
        self.isAutoRefreshEnabled = isAutoRefreshEnabled
    }
}

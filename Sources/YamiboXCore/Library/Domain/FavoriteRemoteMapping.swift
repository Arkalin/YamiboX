import Foundation

public struct FavoriteRemoteMapping: Codable, Hashable, Sendable {
    public var yamiboFavoriteID: String?
    public var yamiboRemoteOrder: Int?
    public var lastSeenAt: Date?

    public init(
        yamiboFavoriteID: String? = nil,
        yamiboRemoteOrder: Int? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.yamiboFavoriteID = yamiboFavoriteID
        self.yamiboRemoteOrder = yamiboRemoteOrder
        self.lastSeenAt = lastSeenAt
    }
}

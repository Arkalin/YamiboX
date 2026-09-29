import Foundation

public struct FavoriteRemoteMapping: Codable, Hashable, Sendable {
    public var yamiboFavoriteID: String?
    public var yamiboRemoteOrder: Int?
    public var lastSeenAt: Date?

    public var hasResolvedFavoriteID: Bool {
        FavoriteRemoteIdentity.normalizedID(yamiboFavoriteID) != nil
    }

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

/// The local library uses `favorite:<tid>` as a stable UI identity when a
/// remote favorite has no server id. That identity must never cross the
/// network as the server's `favorite[]` value.
enum FavoriteRemoteIdentity {
    static func normalizedID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return nil
        }
        return value
    }
}

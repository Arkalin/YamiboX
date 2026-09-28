import Foundation

/// A favorite-update local notification ready for delivery. The identifier is
/// stable per favorite target so a re-detection for the same favorite
/// replaces its previous notification instead of stacking a duplicate —
/// mirroring how `FavoriteUpdateStore.insertEvent` keeps one undismissed
/// event per target.
public struct FavoriteUpdateNotification: Equatable, Sendable {
    public static let targetIDUserInfoKey = "favoriteUpdateTargetID"
    public static let threadIdentifier = "favorite-updates"

    public var identifier: String
    public var targetID: String
    public var title: String
    public var subtitle: String?
    public var body: String
    /// App icon badge to apply with this delivery: the unread undismissed
    /// event count, matching the favorites bell badge.
    public var badgeCount: Int

    public init(event: FavoriteUpdateEvent, badgeCount: Int) {
        identifier = Self.identifier(forTargetID: event.target.id)
        targetID = event.target.id
        title = event.title
        subtitle = event.forumName
        body = event.summary.displayText
        self.badgeCount = badgeCount
    }

    public static func identifier(forTargetID targetID: String) -> String {
        "favorite-update:\(targetID)"
    }
}

public enum FavoriteUpdateNotificationAuthorization: Sendable {
    case notDetermined
    case granted
    case denied
}

/// Seam over the system notification center so update-notification behavior
/// is testable without touching `UNUserNotificationCenter`.
public protocol FavoriteUpdateNotifying: Sendable {
    func authorization() async -> FavoriteUpdateNotificationAuthorization
    func requestAuthorization() async -> Bool
    func deliver(_ notification: FavoriteUpdateNotification) async
    func removeDelivered(identifiers: [String]) async
    func setBadgeCount(_ count: Int) async
}

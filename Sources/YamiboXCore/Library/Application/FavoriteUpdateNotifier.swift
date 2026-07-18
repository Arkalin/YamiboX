import Foundation
import UserNotifications

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
        body = Self.body(for: event.summary)
        self.badgeCount = badgeCount
    }

    public static func identifier(forTargetID targetID: String) -> String {
        "favorite-update:\(targetID)"
    }

    /// Notification body copy for a summary — the same localized strings as
    /// the UI layer's `FavoriteUpdateSummary.displayText` (both resolve the
    /// identical keys from this module's `Localizable.strings`), duplicated
    /// here because that presentation extension lives in the UI target and
    /// deliveries now originate from this Core engine.
    private static func body(for summary: FavoriteUpdateSummary) -> String {
        switch summary {
        case let .newReplies(count):
            L10n.string("favorites.updates.summary.replies", count)
        case let .newPages(count):
            L10n.string("favorites.updates.summary.pages", count)
        case let .newChapters(count):
            L10n.string("favorites.updates.summary.new_chapters", count)
        case .changed:
            L10n.string("favorites.updates.summary.changed")
        }
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

/// Production notifier backed by `UNUserNotificationCenter`.
public struct UserNotificationFavoriteUpdateNotifier: FavoriteUpdateNotifying {
    public init() {}

    public func authorization() async -> FavoriteUpdateNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            YamiboLog.library.error("Favorite update notification authorization request failed: \(error.localizedDescription)")
            return false
        }
    }

    public func deliver(_ notification: FavoriteUpdateNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle {
            content.subtitle = subtitle
        }
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = FavoriteUpdateNotification.threadIdentifier
        content.userInfo = [FavoriteUpdateNotification.targetIDUserInfoKey: notification.targetID]
        content.badge = NSNumber(value: notification.badgeCount)
        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            YamiboLog.library.error("Failed to deliver favorite update notification \(notification.identifier): \(error.localizedDescription)")
        }
    }

    public func removeDelivered(identifiers: [String]) async {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func setBadgeCount(_ count: Int) async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(count)
        } catch {
            YamiboLog.library.error("Failed to set favorite update badge count: \(error.localizedDescription)")
        }
    }
}

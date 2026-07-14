import Foundation
import UserNotifications
import YamiboXCore

/// A favorite-update local notification ready for delivery. The identifier is
/// stable per favorite target so a re-detection for the same favorite
/// replaces its previous notification instead of stacking a duplicate —
/// mirroring how `FavoriteUpdateStore.insertEvent` keeps one undismissed
/// event per target.
struct FavoriteUpdateNotification: Equatable, Sendable {
    static let targetIDUserInfoKey = "favoriteUpdateTargetID"
    static let threadIdentifier = "favorite-updates"

    var identifier: String
    var targetID: String
    var title: String
    var subtitle: String?
    var body: String
    /// App icon badge to apply with this delivery: the unread undismissed
    /// event count, matching the favorites bell badge.
    var badgeCount: Int

    init(event: FavoriteUpdateEvent, badgeCount: Int) {
        identifier = Self.identifier(forTargetID: event.target.id)
        targetID = event.target.id
        title = event.title
        subtitle = event.forumName
        body = event.summary.displayText
        self.badgeCount = badgeCount
    }

    static func identifier(forTargetID targetID: String) -> String {
        "favorite-update:\(targetID)"
    }
}

enum FavoriteUpdateNotificationAuthorization: Sendable {
    case notDetermined
    case granted
    case denied
}

/// Seam over the system notification center so update-notification behavior
/// is testable without touching `UNUserNotificationCenter`.
protocol FavoriteUpdateNotifying: Sendable {
    func authorization() async -> FavoriteUpdateNotificationAuthorization
    func requestAuthorization() async -> Bool
    func deliver(_ notification: FavoriteUpdateNotification) async
    func removeDelivered(identifiers: [String]) async
    func setBadgeCount(_ count: Int) async
}

/// Production notifier backed by `UNUserNotificationCenter`.
struct UserNotificationFavoriteUpdateNotifier: FavoriteUpdateNotifying {
    func authorization() async -> FavoriteUpdateNotificationAuthorization {
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

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            YamiboLog.library.error("Favorite update notification authorization request failed: \(error.localizedDescription)")
            return false
        }
    }

    func deliver(_ notification: FavoriteUpdateNotification) async {
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

    func removeDelivered(identifiers: [String]) async {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func setBadgeCount(_ count: Int) async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(count)
        } catch {
            YamiboLog.library.error("Failed to set favorite update badge count: \(error.localizedDescription)")
        }
    }
}

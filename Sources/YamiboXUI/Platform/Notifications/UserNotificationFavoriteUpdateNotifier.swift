import Foundation
import UserNotifications
import YamiboXCore

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

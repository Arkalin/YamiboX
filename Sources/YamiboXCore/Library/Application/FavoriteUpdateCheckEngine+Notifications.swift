import Foundation

extension FavoriteUpdateCheckEngine {

    public func notificationsEnabled() async -> Bool {
        guard let settingsStore else { return false }
        return await settingsStore.load().favorites.updateNotificationsEnabled
    }

    @discardableResult
    public func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        guard let settingsStore, let notifier else { return false }
        var effective = enabled
        if enabled {
            switch await notifier.authorization() {
            case .granted:
                break
            case .notDetermined:
                effective = await notifier.requestAuthorization()
            case .denied:
                effective = false
            }
        }
        let effectiveValue = effective
        do {
            try await settingsStore.update { $0.favorites.updateNotificationsEnabled = effectiveValue }
        } catch {
            YamiboLog.persistence.error("Failed to persist favorite update notification toggle: \(error.localizedDescription)")
        }
        if !effective {
            let identifiers = events.map { FavoriteUpdateNotification.identifier(forTargetID: $0.target.id) }
            await notifier.removeDelivered(identifiers: identifiers)
            await notifier.setBadgeCount(0)
        }
        return effective
    }

    public func notificationsBlockedBySystem() async -> Bool {
        guard let notifier, await notificationsEnabled() else { return false }
        return await notifier.authorization() == .denied
    }

    func deliverNotificationIfEnabled(for event: FavoriteUpdateEvent, runEvents: FavoriteUpdateRunEventAccumulator) async {
        notificationBadgeSequence &+= 1
        let sequence = notificationBadgeSequence
        let runID = snapshot?.runID
        guard let notifier, await notificationsEnabled() else { return }
        guard await notifier.authorization() == .granted else { return }
        do {
            let unreadCount: Int
            if let runID {
                let captured = runEvents.snapshot()
                unreadCount = try await updateStore.unreadEventCount(
                    runEventCount: captured.count, materializeRunEvents: captured.materialize,
                    replacingWith: event, runID: runID, sequence: sequence
                )
            } else {
                unreadCount = try await updateStore.unreadEventCount(mergingRunEvents: runEvents.materialize())
            }
            await notifier.deliver(FavoriteUpdateNotification(event: event, badgeCount: unreadCount))
        } catch {
            YamiboLog.persistence.error("Failed to read favorite update notification badge: \(error)")
        }
    }

    func cleanUpNotifications(forTargetIDs targetIDs: [String]) async {
        guard let notifier else { return }
        do {
            let state = try await updateStore.loadState()
            let unread = state.events.filter { $0.readAt == nil && $0.dismissedAt == nil }
            let unreadTargets = Set(unread.map(\.target.id))
            let handledTargets = Set(targetIDs).subtracting(unreadTargets)
            if !handledTargets.isEmpty {
                await notifier.removeDelivered(identifiers: handledTargets.map(FavoriteUpdateNotification.identifier(forTargetID:)))
            }
            let count = await notificationsEnabled() ? unread.count : 0
            await notifier.setBadgeCount(count)
        } catch {
            reportError(error)
        }
    }
}

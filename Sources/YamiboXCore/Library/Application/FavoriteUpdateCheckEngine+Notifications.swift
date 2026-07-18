import Foundation

extension FavoriteUpdateCheckEngine {

    // MARK: - Update notifications

    /// Whether detected updates are delivered as local notifications.
    public func notificationsEnabled() async -> Bool {
        guard let settingsStore else { return false }
        return await settingsStore.load().favorites.updateNotificationsEnabled
    }

    /// Persists the notification toggle and returns the effective value.
    /// Enabling requests system authorization first, so the stored setting
    /// can only be true after a grant — a denied request leaves it off.
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
        var settings = await settingsStore.load()
        settings.favorites.updateNotificationsEnabled = effective
        do {
            try await settingsStore.save(settings)
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

    /// True when the user's toggle is on but the system permission has since
    /// been revoked — deliveries are silently skipped in that state.
    public func notificationsBlockedBySystem() async -> Bool {
        guard let notifier, await notificationsEnabled() else { return false }
        return await notifier.authorization() == .denied
    }

    /// Delivers a local notification for a freshly inserted event. Sharing
    /// the event's target-keyed identifier means an accumulated re-detection
    /// replaces the favorite's previous notification instead of stacking.
    /// The badge is the unread count of the caller's in-memory run-in-progress
    /// event list merged over the current store state — neither side alone is
    /// right mid-run: the store is missing this run's not-yet-committed
    /// detections, and the in-memory list is missing read/dismiss marks the
    /// user applied since the run snapshotted it.
    func deliverNotificationIfEnabled(for event: FavoriteUpdateEvent, runEvents: [FavoriteUpdateEvent]) async {
        guard let notifier, await notificationsEnabled() else { return }
        guard await notifier.authorization() == .granted else { return }
        let unreadCount = await updateStore.unreadEventCount(mergingRunEvents: runEvents)
        await notifier.deliver(FavoriteUpdateNotification(event: event, badgeCount: unreadCount))
    }

    /// Removes the delivered notifications for events the user has handled
    /// in-app and re-syncs the icon badge to the remaining unread count.
    func cleanUpNotifications(forTargetIDs targetIDs: [String]) async {
        guard let notifier else { return }
        if !targetIDs.isEmpty {
            await notifier.removeDelivered(identifiers: targetIDs.map(FavoriteUpdateNotification.identifier(forTargetID:)))
        }
        guard await notificationsEnabled() else { return }
        await notifier.setBadgeCount(events.filter { $0.readAt == nil }.count)
    }
}

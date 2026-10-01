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
        notificationBadgeSequence &+= 1
        let sequence = notificationBadgeSequence
        let runID = snapshot?.runID
        guard let notifier, await notificationsEnabled() else { return }
        guard await notifier.authorization() == .granted else { return }
        do {
            let unreadCount: Int
            if let runID {
                unreadCount = try await updateStore.unreadEventCount(mergingRunEvents: runEvents, replacingWith: event, runID: runID, sequence: sequence)
            } else {
                unreadCount = try await updateStore.unreadEventCount(mergingRunEvents: runEvents)
            }
            await notifier.deliver(FavoriteUpdateNotification(event: event, badgeCount: unreadCount))
        } catch {
            YamiboLog.persistence.error("Failed to read favorite update notification badge: \(error)")
        }
    }

    /// Removes the delivered notifications for events the user has handled
    /// in-app and re-syncs the icon badge to the remaining unread count.
    func cleanUpNotifications(forTargetIDs targetIDs: [String]) async {
        guard let notifier else { return }
        do {
            let state = try await updateStore.loadState()
            let unread = state.events.filter { $0.readAt == nil && $0.dismissedAt == nil }
            let unreadTargets = Set(unread.map(\.target.id))
            // Do not remove a newer notification for the same target that arrived
            // while the user was acknowledging the captured event IDs.
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

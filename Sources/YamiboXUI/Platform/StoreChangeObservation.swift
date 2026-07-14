import Foundation

/// The store-changed subscription every view model repeats: listen for a
/// store's `didChangeNotification`, drop posts whose `changeID` doesn't match
/// this store instance (other instances — e.g. parallel tests — share the
/// notification name), and run a handler per surviving change.
@MainActor
enum StoreChangeObservation {
    /// Starts a long-lived observation task. Cancel it (typically in
    /// `deinit`) to end the observation; capture `self` weakly in `onChange`.
    static func task(
        named name: Notification.Name,
        changeIDKey: String,
        changeID: @escaping @Sendable () -> String,
        onChange: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            for await notification in NotificationCenter.default.notifications(named: name) {
                guard !Task.isCancelled else { return }
                guard let incoming = notification.userInfo?[changeIDKey] as? String,
                      incoming == changeID() else {
                    continue
                }
                await onChange()
            }
        }
    }
}

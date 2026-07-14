import Foundation

struct WebDAVSyncPolicyModule: Sendable {
    init() {}

    func canSynchronizeAutomatically(
        settings: WebDAVSyncSettings,
        session: SessionState
    ) -> Bool {
        settings.isAutoSyncEnabled &&
            settings.isConfigured &&
            session.isLoggedIn &&
            !session.cookie.isEmpty
    }
}

import Foundation
import YamiboXCore

enum ForumWebSessionSyncAction: Equatable {
    case none
    case injectCookies(cookieHeader: String, reload: Bool)
    case clearCookies(reload: Bool)
}

struct ForumWebSessionSyncState {
    private var lastCookieHeader: String?
    private var lastAuthenticationCookieValue: String?

    mutating func markPersistedWebSession(cookieHeader: String) {
        lastCookieHeader = cookieHeader
        lastAuthenticationCookieValue = SessionState.authenticationCookieValue(in: cookieHeader)
    }

    mutating func action(
        for sessionState: SessionState,
        reloadIfNeeded: Bool
    ) -> ForumWebSessionSyncAction {
        let authenticationValue = SessionState.authenticationCookieValue(in: sessionState.cookie)
        if authenticationValue != nil {
            let cookieChanged = sessionState.cookie != lastCookieHeader
            let authenticationChanged = authenticationValue != lastAuthenticationCookieValue
            guard cookieChanged || authenticationChanged else { return .none }

            lastCookieHeader = sessionState.cookie
            lastAuthenticationCookieValue = authenticationValue
            return .injectCookies(
                cookieHeader: sessionState.cookie,
                reload: reloadIfNeeded || authenticationChanged
            )
        }

        if sessionState.cookie.isEmpty {
            guard lastCookieHeader != sessionState.cookie || lastAuthenticationCookieValue != nil else {
                return .none
            }

            let hadSynchronizedCookies = lastCookieHeader?.isEmpty == false || lastAuthenticationCookieValue != nil
            lastCookieHeader = sessionState.cookie
            lastAuthenticationCookieValue = nil
            return .clearCookies(reload: reloadIfNeeded && hadSynchronizedCookies)
        }

        guard sessionState.cookie != lastCookieHeader else { return .none }
        lastCookieHeader = sessionState.cookie
        lastAuthenticationCookieValue = nil
        return .injectCookies(cookieHeader: sessionState.cookie, reload: false)
    }
}

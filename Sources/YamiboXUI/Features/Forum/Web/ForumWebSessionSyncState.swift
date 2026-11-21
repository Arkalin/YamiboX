import Foundation
import YamiboXCore

enum ForumWebSessionSyncAction: Equatable {
    case none
    case injectWAFCookies
    case injectCookies(reload: Bool)
    case clearCookies(reload: Bool)
}

struct ForumWebSessionSyncState {
    private var lastCookies: [YamiboCookie]?
    private var lastAuthenticationCookieValue: String?
    private var lastNonWAFCookies: [YamiboCookie]?

    mutating func markPersistedWebSession(_ session: SessionState) {
        lastCookies = session.forumCookies
        lastAuthenticationCookieValue = session.authenticationCookieValue
        lastNonWAFCookies = session.forumCookies.filter { !YamiboCookie.isWAFCookie($0.name) }
    }

    mutating func action(
        for sessionState: SessionState,
        reloadIfNeeded: Bool
    ) -> ForumWebSessionSyncAction {
        let authenticationValue = sessionState.authenticationCookieValue
        let cookies = sessionState.forumCookies
        let nonWAFCookies = cookies.filter { !YamiboCookie.isWAFCookie($0.name) }
        let onlyWAFChanged = lastNonWAFCookies == nonWAFCookies
        defer { lastNonWAFCookies = nonWAFCookies }
        if authenticationValue != nil {
            let cookieChanged = cookies != lastCookies
            let authenticationChanged = authenticationValue != lastAuthenticationCookieValue
            guard cookieChanged || authenticationChanged else { return .none }

            lastCookies = cookies
            lastAuthenticationCookieValue = authenticationValue
            return onlyWAFChanged && !authenticationChanged ? .injectWAFCookies : .injectCookies(reload: authenticationChanged)
        }

        if cookies.isEmpty {
            guard lastCookies != cookies || lastAuthenticationCookieValue != nil else {
                return .none
            }

            let hadSynchronizedCookies = lastCookies?.isEmpty == false || lastAuthenticationCookieValue != nil
            lastCookies = cookies
            lastAuthenticationCookieValue = nil
            return .clearCookies(reload: reloadIfNeeded && hadSynchronizedCookies)
        }

        guard cookies != lastCookies else { return .none }
        lastCookies = cookies
        lastAuthenticationCookieValue = nil
        return onlyWAFChanged ? .injectWAFCookies : .injectCookies(reload: false)
    }
}

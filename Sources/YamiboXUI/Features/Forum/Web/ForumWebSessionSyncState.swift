import Foundation
import YamiboXCore

enum ForumWebSessionSyncAction: Equatable {
    case none
    case injectWAFCookies
    case injectCookies(reload: Bool)
    case clearCookies(reload: Bool)
}

struct ForumWebSessionSyncState {
    private var lastCookieHeader: String?
    private var lastAuthenticationCookieValue: String?
    private var lastNonWAFCookies: [YamiboCookie]?

    mutating func markPersistedWebSession(_ session: SessionState) {
        lastCookieHeader = session.cookie
        lastAuthenticationCookieValue = SessionState.authenticationCookieValue(in: session.cookie)
        lastNonWAFCookies = session.cookies.filter { !YamiboCookie.isWAFCookie($0.name) }
    }

    mutating func action(
        for sessionState: SessionState,
        reloadIfNeeded: Bool
    ) -> ForumWebSessionSyncAction {
        let authenticationValue = SessionState.authenticationCookieValue(in: sessionState.cookie)
        let nonWAFCookies = sessionState.cookies.filter { !YamiboCookie.isWAFCookie($0.name) }
        let onlyWAFChanged = lastNonWAFCookies == nonWAFCookies
        defer { lastNonWAFCookies = nonWAFCookies }
        if authenticationValue != nil {
            let cookieChanged = sessionState.cookie != lastCookieHeader
            let authenticationChanged = authenticationValue != lastAuthenticationCookieValue
            guard cookieChanged || authenticationChanged else { return .none }

            lastCookieHeader = sessionState.cookie
            lastAuthenticationCookieValue = authenticationValue
            // Clearance churn updates subresources in place. It is never a
            // reason to reload a successfully displayed page.
            return onlyWAFChanged ? .injectWAFCookies : .injectCookies(reload: authenticationChanged)
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
        return onlyWAFChanged ? .injectWAFCookies : .injectCookies(reload: false)
    }
}

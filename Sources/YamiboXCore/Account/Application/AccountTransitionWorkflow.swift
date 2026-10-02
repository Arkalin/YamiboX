import Foundation

/// Owns the transition ordering and failure cleanup, not dependency assembly.
/// Callers hold the account-operation lease before entering this workflow.
struct AccountTransitionWorkflow: Sendable {
    enum WebDataCleanup: Sendable { case session, all, none }

    let sessionStore: SessionStore
    let syncCoordinator: WebDAVSyncCoordinator
    let lifecycle: AccountTransitionLifecycle
    let unread: MessageUnreadWorkflow
    let blacklist: ForumBlacklistWorkflow
    let stopDownload: @Sendable () async throws -> Void
    let clearAccountCaches: @Sendable () async throws -> Void
    let clearWebData: @Sendable (WebDataCleanup) async -> Void

    func run(
        webDataCleanup: WebDataCleanup = .session,
        _ commit: @escaping @Sendable (UUID) async throws -> Void
    ) async throws {
        try await lifecycle.willBegin()
        let token = try await sessionStore.beginIdentityTransition()
        do {
            try await syncCoordinator.reset {
                do {
                    await unread.prepareForAccountChange()
                    await blacklist.prepareForAccountChange()
                    try await stopDownload()
                    try await lifecycle.willChange()
                    try await clearAccountCaches()
                    try Task.checkCancellation()
                    try await commit(token)
                } catch {
                    await finish(token, webDataCleanup: webDataCleanup)
                    throw error
                }
                await finish(token, webDataCleanup: webDataCleanup)
            }
        } catch {
            await sessionStore.endIdentityTransition(token)
            throw error
        }
    }

    private func finish(_ token: UUID, webDataCleanup: WebDataCleanup) async {
        let state = await sessionStore.load()
        await clearWebData(webDataCleanup)
        await lifecycle.didChange(state)
        await sessionStore.endIdentityTransition(token)
        await unread.finishAccountChange()
        await blacklist.finishAccountChange()
        await lifecycle.didPublish()
    }
}

/// Foundation cookies/cache and the injected platform web store share one policy.
struct AccountWebDataCleaner: Sendable {
    let session: URLSession
    let httpCache: URLCache
    let websiteDataClearer: (any WebsiteDataClearing)?

    @MainActor
    func clear(_ scope: AccountTransitionWorkflow.WebDataCleanup) async {
        switch scope {
        case .all:
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            httpCache.removeAllCachedResponses()
            await websiteDataClearer?.clearAllWebsiteData()
        case .session:
            for storage in [session.configuration.httpCookieStorage, HTTPCookieStorage.shared].compactMap({ $0 }) {
                for cookie in storage.cookies ?? [] where YamiboDomain.containsYamiboDomain(cookie.domain) {
                    storage.deleteCookie(cookie)
                }
            }
            httpCache.removeAllCachedResponses()
            await websiteDataClearer?.clearYamiboCookies()
        case .none:
            break
        }
    }
}

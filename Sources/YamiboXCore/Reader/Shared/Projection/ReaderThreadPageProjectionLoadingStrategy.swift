import Foundation

protocol ReaderThreadPageProjectionRequesting: Sendable {
    var threadID: String { get }
    var view: Int { get }
    var authorID: String? { get }
}

protocol ReaderThreadPageProjectionIdentifying: Hashable, Sendable {
    var threadID: String { get }
    var view: Int { get }
    var authorID: String? { get }
}

protocol ReaderThreadPageProjectionAdapter: Sendable {
    associatedtype Request: ReaderThreadPageProjectionRequesting
    associatedtype Identity: ReaderThreadPageProjectionIdentifying
    associatedtype Projection: Sendable

    var client: YamiboClient { get }
    var forumCacheStore: ForumCacheStore { get }
    var authorScopeErrorContext: String { get }

    func makeIdentity(request: Request, authorID: String) -> Identity
    func offlineSourcePage(
        for request: Request
    ) async -> ReaderProjectionOfflineSourcePageLoad<Identity, ForumThreadPage>?
    func fingerprintIdentityComponents(for identity: Identity) -> [String]
    func cachedProjection(for identity: Identity) async -> Projection?
    func isReusableProjection(_ projection: Projection, identity: Identity, fingerprint: String) -> Bool
    func buildProjection(sourcePage: ForumThreadPage, identity: Identity, fingerprint: String) throws -> Projection
    func saveProjection(_ projection: Projection) async throws
}

struct ReaderThreadPageProjectionLoadingStrategy<Adapter: ReaderThreadPageProjectionAdapter>: ReaderProjectionLoadingStrategy {
    typealias Request = Adapter.Request
    typealias Identity = Adapter.Identity
    typealias Projection = Adapter.Projection
    typealias SourcePage = ForumThreadPage

    let adapter: Adapter

    func identity(for request: Request, ignoresCache: Bool) async throws -> Identity {
        if let authorID = Self.normalizedAuthorID(request.authorID) {
            return adapter.makeIdentity(request: request, authorID: authorID)
        }

        let thread = ThreadIdentity(tid: request.threadID)
        let discoveryPage: ForumThreadPage
        if !ignoresCache,
           let cached = await adapter.forumCacheStore.loadThreadPage(thread: thread, page: 1, authorID: nil) {
            discoveryPage = cached
        } else {
            let html = try await fetchThreadHTML(threadID: thread.tid, view: 1, authorID: nil)
            discoveryPage = try ForumThreadPageHTMLParser.parsePage(
                from: html,
                thread: thread,
                fallbackTitle: nil
            )
            do {
                try await adapter.forumCacheStore.saveThreadPage(
                    discoveryPage,
                    thread: thread,
                    pageNumber: 1,
                    authorID: nil
                )
            } catch {
                YamiboLog.forum.warning("identity(for:ignoresCache:): failed to cache discovery page tid=\(thread.tid, privacy: .public): \(error)")
            }
            if let authorID = Self.normalizedAuthorID(
                YamiboThreadHTMLFacts.onlyAuthorID(from: html, threadID: thread.tid)
            ) {
                return adapter.makeIdentity(request: request, authorID: authorID)
            }
        }

        if let authorID = Self.normalizedAuthorID(discoveryPage.posts.first?.author.uid) {
            return adapter.makeIdentity(request: request, authorID: authorID)
        }
        throw YamiboError.parsingFailed(context: adapter.authorScopeErrorContext)
    }

    func onlineSourcePage(
        for request: Request,
        identity: Identity,
        ignoresCache: Bool
    ) async throws -> ReaderProjectionSourcePageLoad<ForumThreadPage> {
        let thread = ThreadIdentity(tid: identity.threadID)
        if !ignoresCache,
           let cached = await adapter.forumCacheStore.loadThreadPage(
               thread: thread,
               page: identity.view,
               authorID: identity.authorID
           ) {
            return ReaderProjectionSourcePageLoad(sourcePage: cached, loadedOnline: false)
        }

        let html = try await fetchThreadHTML(
            threadID: identity.threadID,
            view: identity.view,
            authorID: identity.authorID
        )
        let parsed = try ForumThreadPageHTMLParser.parsePage(from: html, thread: thread, fallbackTitle: nil)
        do {
            try await adapter.forumCacheStore.saveThreadPage(
                parsed,
                thread: thread,
                pageNumber: identity.view,
                authorID: identity.authorID
            )
        } catch {
            YamiboLog.forum.warning("onlineSourcePage(for:identity:ignoresCache:): failed to cache thread page tid=\(thread.tid, privacy: .public) page=\(identity.view, privacy: .public): \(error)")
        }
        return ReaderProjectionSourcePageLoad(sourcePage: parsed, loadedOnline: true)
    }

    func offlineSourcePage(
        for request: Request
    ) async -> ReaderProjectionOfflineSourcePageLoad<Identity, ForumThreadPage>? {
        await adapter.offlineSourcePage(for: request)
    }

    func fingerprint(sourcePage: ForumThreadPage, identity: Identity) -> String {
        ReaderThreadPageProjectionFingerprint.fingerprint(
            page: sourcePage,
            identityComponents: adapter.fingerprintIdentityComponents(for: identity)
        )
    }

    func cachedProjection(for identity: Identity) async -> Projection? {
        await adapter.cachedProjection(for: identity)
    }

    func isReusableProjection(_ projection: Projection, identity: Identity, fingerprint: String) -> Bool {
        adapter.isReusableProjection(projection, identity: identity, fingerprint: fingerprint)
    }

    func deriveProjection(
        sourcePage: ForumThreadPage,
        identity: Identity,
        fingerprint: String
    ) throws -> Projection {
        try adapter.buildProjection(sourcePage: sourcePage, identity: identity, fingerprint: fingerprint)
    }

    func saveProjection(_ projection: Projection) async throws {
        try await adapter.saveProjection(projection)
    }

    private func fetchThreadHTML(threadID: String, view: Int, authorID: String?) async throws -> String {
        do {
            return try await adapter.client.fetchThreadById(tid: threadID, authorID: authorID, page: view)
        } catch let error as YamiboError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw YamiboError.offline
            default:
                throw YamiboError.underlying(error.localizedDescription)
            }
        }
    }

    static func normalizedAuthorID(_ authorID: String?) -> String? {
        let value = authorID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum ReaderThreadPageProjectionFingerprint {
    static func fingerprint(page: ForumThreadPage, identityComponents: [String]) -> String {
        let value = (
            identityComponents + [
                page.posts.map { post in
                    [
                        post.postID,
                        post.author.uid ?? "",
                        post.contentHTML,
                        post.images.map(\.url).joined(separator: ",")
                    ].joined(separator: "\u{1E}")
                }.joined(separator: "\u{1D}"),
                String(page.pageNavigation?.totalPages ?? 0)
            ]
        ).joined(separator: "\u{1F}")

        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

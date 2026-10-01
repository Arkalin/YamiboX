import Foundation
import os

public actor YamiboThreadRouteResolver {
    private let client: YamiboClient
    private let settingsStore: SettingsStore

    init(client: YamiboClient, settingsStore: SettingsStore = SettingsStore()) {
        self.client = client
        self.settingsStore = settingsStore
    }

    public func resolve(_ request: YamiboThreadRouteRequest) async throws -> YamiboThreadRouteTarget {
        try await resolveWithPage(request).target
    }

    public func resolveWithPage(_ request: YamiboThreadRouteRequest) async throws -> YamiboThreadRouteResolution {
        try await resolve(request, allowsAuthenticationFallback: true)
    }

    func resolveForFavoriteSync(_ request: YamiboThreadRouteRequest) async throws -> YamiboThreadRouteTarget {
        // Background imports cannot hand an authentication failure to a web
        // view; keep the error so the sync engine can stop the run.
        try await resolve(request, allowsAuthenticationFallback: false).target
    }

    private func resolve(
        _ request: YamiboThreadRouteRequest,
        allowsAuthenticationFallback: Bool
    ) async throws -> YamiboThreadRouteResolution {
        let requestURL = URL(string: request.threadURL.absoluteString, relativeTo: YamiboDomain.baseURL)?.absoluteURL
            ?? request.threadURL.absoluteURL
        if !YamiboForumEnvironment.current.allowsThreadResolution(requestURL) {
            return YamiboThreadRouteResolution(.webFallback(requestURL))
        }
        var canonicalURL = canonicalThreadURL(from: requestURL) ?? requestURL
        let targetPostID = request.targetPostID ?? postID(from: requestURL)
        var baseInitialPage = pageNumber(from: requestURL) ?? pageNumber(from: canonicalURL) ?? 1
        var locationMetadata: YamiboThreadMetadata?
        var locatedPage: ForumThreadPage?
        var locationIsForward = false
        if isFindPostURL(requestURL) {
            do {
                var locationURL = requestURL
                if var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: true) {
                    // Classification may only become known after this response.
                    // Every native reader uses forward pages, including a plain
                    // thread reached through contentRoute on a reverse-default thread.
                    var items = components.queryItems ?? []
                    items.removeAll { $0.name == "ordertype" }
                    items.append(.init(name: "ordertype", value: "2"))
                    components.queryItems = items
                    locationURL = components.url ?? requestURL
                }
                let response = try await ForumPageClient(transport: client).fetchDocument(url: ForumWebPagePolicy.secureURL(locationURL))
                guard response.continuationURL == nil, response.file == nil,
                      ForumWebPagePolicy.requiresForumHandling(response.url) else {
                    return YamiboThreadRouteResolution(.webFallback(requestURL))
                }
                let metadata = try YamiboThreadMetadataHTMLParser.parse(from: response.html, url: response.url)
                guard let tid = metadata.tid ?? threadID(from: canonicalURL) ?? request.threadID else {
                    return YamiboThreadRouteResolution(.webFallback(requestURL))
                }
                let thread = ThreadIdentity(tid: tid, fid: metadata.fid)
                let page = try ForumThreadPageHTMLParser.parsePage(from: response.html, thread: thread, fallbackTitle: metadata.title)
                var components = URLComponents(url: response.url, resolvingAgainstBaseURL: true)!
                components.path = "/forum.php"
                components.queryItems = [.init(name: "mod", value: "viewthread"), .init(name: "tid", value: tid)]
                canonicalURL = YamiboThreadURLCanonicalizer.canonicalThreadURL(from: components.url!)
                baseInitialPage = pageNumber(from: response.url) ?? page.pageNavigation?.currentPage ?? baseInitialPage
                locationMetadata = metadata
                locationMetadata?.tid = tid
                // Only an unfiltered forward touch page can seed the ordinary
                // reader. A scoped/desktop response still supplies location.
                let items = URLComponents(url: response.url, resolvingAgainstBaseURL: true)?.queryItems ?? []
                locationIsForward = items.value(named: "ordertype") == "2"
                if items.value(named: "mobile") == "2",
                   items.value(named: "authorid")?.nilIfBlank == nil,
                   locationIsForward,
                   items.value(named: "viewpid")?.nilIfBlank == nil,
                   targetPostID.map({ id in page.posts.contains { $0.postID == id } }) ?? true {
                    var preloaded = page
                    preloaded.pageNavigation = ForumPageNavigation(
                        currentPage: baseInitialPage,
                        totalPages: page.pageNavigation?.totalPages
                    )
                    locatedPage = preloaded
                }
            } catch {
                if Task.isCancelled || LoadDiagnosticError.isCancellation(error) { throw error }
                let classified = LoadDiagnosticError.classificationError(error)
                if let yamiboError = classified as? YamiboError,
                   yamiboError == .notAuthenticated || yamiboError == .floodControl || yamiboError == .securityVerificationRequired {
                    if allowsAuthenticationFallback { return YamiboThreadRouteResolution(.webFallback(requestURL)) }
                    throw error
                }
                if threadID(from: canonicalURL) == nil && request.threadID == nil {
                    if classified is URLError || classified as? YamiboError == .offline { throw error }
                    if let error = classified as? YamiboError {
                        switch error {
                        case .parsingFailed, .underlying, .emptyHTML, .unreadableBody,
                             .invalidResponse(statusCode: 403), .invalidResponse(statusCode: 404):
                            return YamiboThreadRouteResolution(.webFallback(requestURL))
                        default: break
                        }
                    }
                    throw error
                }
                YamiboLog.forum.warning("Failed to locate post; retaining known thread and page: \(error)")
            }
        }

        // All entry points share the location response before classification.
        if request.intent == .nativeThreadReader || request.readerOverride == .plainThread {
            // A redirect can discard the requested order. Neither its page
            // number nor its body is safe to use as a forward location then.
            if locationMetadata != nil, !locationIsForward {
                return YamiboThreadRouteResolution(.webFallback(requestURL))
            }
            let tid = locationMetadata?.tid ?? request.threadID
                ?? threadID(from: canonicalURL)
                ?? YamiboForumURLIdentity.threadID(from: canonicalURL.absoluteString)
                ?? ""
            let thread = ThreadIdentity(
                tid: tid,
                fid: locationMetadata?.fid ?? request.tapContext.containingFid ?? request.threadFid
            )
            guard !tid.isEmpty else { return YamiboThreadRouteResolution(.webFallback(requestURL)) }
            let initialPage = baseInitialPage
            return YamiboThreadRouteResolution(.thread(
                YamiboThreadRoutePayload(
                    thread: thread,
                    title: request.title ?? locationMetadata?.title ?? L10n.string("forum.default_title"),
                    authorID: request.authorID,
                    canonicalURL: canonicalURL,
                    requestedURL: requestURL,
                    initialPage: initialPage,
                    targetPostID: targetPostID
                )
            ), preloadedPage: locatedPage)
        }

        let settings = await settingsStore.load().boardReader

        let initialFid = locationMetadata?.fid ?? request.tapContext.containingFid ?? request.threadFid
        let initialKind = kindForKnownInputs(
            fid: initialFid,
            knownThreadKind: request.knownThreadKind,
            title: nil,
            settings: settings
        )

        // An override already settles the classification, so the metadata
        // round-trip it exists to inform would be pure latency.
        let metadata: YamiboThreadMetadata?
        var classificationHTML: String?
        if let locationMetadata {
            metadata = locationMetadata
        } else if !isFindPostURL(requestURL), request.readerOverride == nil,
           shouldFetchMetadata(fid: initialFid, knownThreadKind: request.knownThreadKind, settings: settings) {
            do {
                let seed = try await loadMetadata(
                    for: canonicalURL, fallbackURL: requestURL,
                    allowsAuthenticationFallback: allowsAuthenticationFallback
                )
                metadata = seed.metadata
                classificationHTML = seed.html
            } catch let fallback as YamiboThreadRouteResolverWebFallback {
                return YamiboThreadRouteResolution(.webFallback(fallback.url))
            }
        } else {
            metadata = nil
        }

        let tid = locationMetadata?.tid ?? request.threadID
            ?? metadata?.tid
            ?? threadID(from: canonicalURL)
            ?? YamiboForumURLIdentity.threadID(from: canonicalURL.absoluteString)
            ?? ""
        guard !tid.isEmpty else { return YamiboThreadRouteResolution(.webFallback(requestURL)) }
        let fid = initialFid ?? metadata?.fid
        let title = request.title ?? metadata?.title
        let authorID = request.authorID ?? metadata?.authorID
        let thread = ThreadIdentity(tid: tid, fid: fid)
        let kind: YamiboThreadKind = if let readerOverride = request.readerOverride {
            readerOverride.threadKind
        } else if metadata == nil {
            initialKind
        } else {
            kindForKnownInputs(
                fid: fid,
                knownThreadKind: request.knownThreadKind,
                title: [title, metadata?.sectionText].compactMap { $0 }.joined(separator: " "),
                settings: settings
            )
        }

        switch kind {
        case .novel:
            return YamiboThreadRouteResolution(.novel(
                YamiboThreadRoutePayload(
                    thread: thread,
                    title: title ?? L10n.string("reader.title"),
                    authorID: authorID,
                    canonicalURL: canonicalURL,
                    requestedURL: requestURL,
                    initialPage: baseInitialPage,
                    targetPostID: targetPostID
                )
            ))
        case .manga:
            let payload = YamiboThreadRoutePayload(
                thread: thread,
                title: title ?? L10n.string("manga.reader.title"),
                authorID: authorID,
                canonicalURL: canonicalURL,
                requestedURL: requestURL,
                initialPage: baseInitialPage,
                targetPostID: targetPostID
            )
            // Classification (kind == .manga) picks the manga reader; the
            // board's smart bit only decides which entry point: detail page
            // (`.manga`) when smart is on, direct single-chapter reading
            // (`.mangaDirect`) otherwise. The strict rule applies — an
            // unconfigured or missing fid never reports smart-enabled. A
            // per-tap 漫画 override overrides the classification only, not
            // this bit: it never turns Smart Comic Mode on for a board the
            // user did not configure that way, so it opens the thread on its
            // own exactly like an unconfigured manga thread.
            guard settings.isSmartComicModeEnabled(forumID: fid) else {
                return YamiboThreadRouteResolution(.mangaDirect(payload))
            }
            return YamiboThreadRouteResolution(.manga(payload))
        case .regular, .unknown:
            if locationMetadata != nil, !locationIsForward {
                return YamiboThreadRouteResolution(.webFallback(requestURL))
            }
            let initialPage = baseInitialPage
            if initialPage == 1, let classificationHTML {
                locatedPage = try LoadDiagnosticError.parsing(html: classificationHTML, context: canonicalURL.absoluteString) {
                    try ForumThreadPageHTMLParser.parsePage(from: classificationHTML, thread: thread, fallbackTitle: title)
                }
            }
            return YamiboThreadRouteResolution(.thread(
                YamiboThreadRoutePayload(
                    thread: thread,
                    title: title ?? L10n.string("forum.default_title"),
                    authorID: authorID,
                    canonicalURL: canonicalURL,
                    requestedURL: requestURL,
                    initialPage: initialPage,
                    targetPostID: targetPostID
                )
            ), preloadedPage: locatedPage)
        }
    }

    private func shouldFetchMetadata(
        fid: String?,
        knownThreadKind: YamiboThreadKind?,
        settings: BoardReaderSettings
    ) -> Bool {
        if let fid, settings.threadKind(forumID: fid) != .unknown {
            return false
        }
        if let knownThreadKind, knownThreadKind != .unknown {
            return false
        }
        return fid == nil
    }

    private func loadMetadata(
        for url: URL, fallbackURL: URL, allowsAuthenticationFallback: Bool
    ) async throws -> (metadata: YamiboThreadMetadata, html: String) {
        do {
            // Probe in the same unfiltered, forward order as the native reader.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            var items = components?.queryItems ?? []
            items.removeAll { ["ordertype", "authorid", "viewpid"].contains($0.name) }
            items.append(.init(name: "ordertype", value: "2"))
            components?.queryItems = items
            let html = try await client.fetchHTML(for: .thread(url: components?.url ?? url, page: 1, authorID: nil))
            let metadata = try LoadDiagnosticError.parsing(html: html, context: url.absoluteString) {
                try YamiboThreadMetadataHTMLParser.parse(from: html, url: url)
            }
            return (metadata, html)
        } catch where allowsAuthenticationFallback && (LoadDiagnosticError.classificationError(error) as? YamiboError) == .notAuthenticated {
            throw YamiboThreadRouteResolverWebFallback(url: fallbackURL)
        } catch where allowsAuthenticationFallback && (LoadDiagnosticError.classificationError(error) as? YamiboError) == .floodControl {
            throw YamiboThreadRouteResolverWebFallback(url: fallbackURL)
        }
    }

    private func kindForKnownInputs(
        fid: String?,
        knownThreadKind: YamiboThreadKind?,
        title: String?,
        settings: BoardReaderSettings
    ) -> YamiboThreadKind {
        if let fid {
            let configuredKind = settings.threadKind(forumID: fid)
            if configuredKind != .unknown {
                return configuredKind
            }
            if let knownThreadKind, knownThreadKind != .unknown {
                return knownThreadKind
            }
            return .regular
        }

        if let knownThreadKind, knownThreadKind != .unknown {
            return knownThreadKind
        }

        if isNovelMarker(title) {
            return .novel
        }

        return .regular
    }

    private func isNovelMarker(_ value: String?) -> Bool {
        guard let value else { return false }
        let markers = ["文學區", "文学区", "原创小说区", "原創小說區", "轻小说/译文区", "輕小說/譯文區", "TXT小说区", "TXT小說區"]
        return markers.contains { value.localizedCaseInsensitiveContains($0) }
    }

    private func canonicalThreadURL(from url: URL) -> URL? {
        if url.host == nil {
            return YamiboThreadURLCanonicalizer.canonicalThreadURL(from: url)
        }
        if YamiboDomain.isYamiboHost(url) {
            return YamiboThreadURLCanonicalizer.canonicalThreadURL(from: url)
        }
        return nil
    }

    private func isFindPostURL(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return url.absoluteString.localizedCaseInsensitiveContains("findpost")
        }
        return items.value(named: "goto") == "findpost"
            || (items.value(named: "mod") == "redirect" && items.value(named: "pid") != nil)
    }

    private func threadID(from url: URL) -> String? {
        YamiboThreadURLCanonicalizer.threadID(from: url)
    }

    private func postID(from url: URL) -> String? {
        if let queryPostID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "pid" })?
            .value?
            .nilIfBlank {
            return queryPostID
        }

        guard let fragment = url.fragment?.nilIfBlank else { return nil }
        if let match = HTMLTextExtractor.firstMatch(pattern: #"^pid(\d+)$"#, in: fragment),
           match.count >= 2 {
            return match[1].nilIfBlank
        }
        return nil
    }

    private func pageNumber(from url: URL) -> Int? {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "page" })?
            .value
            .flatMap(Int.init),
           value > 0 {
            return value
        }

        return HTMLTextExtractor.firstMatch(pattern: #"thread-\d+-(\d+)-\d+\.html"#, in: url.absoluteString)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }

}

private struct YamiboThreadRouteResolverWebFallback: Error {
    var url: URL
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}

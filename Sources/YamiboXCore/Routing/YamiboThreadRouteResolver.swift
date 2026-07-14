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
        let requestURL = URL(string: request.threadURL.absoluteString, relativeTo: YamiboDomain.baseURL)?.absoluteURL
            ?? request.threadURL.absoluteURL
        let canonicalURL = canonicalThreadURL(from: requestURL) ?? requestURL
        let targetPostID = request.targetPostID ?? postID(from: requestURL)
        let baseInitialPage = pageNumber(from: requestURL) ?? pageNumber(from: canonicalURL) ?? 1

        if request.intent == .nativeThreadReader {
            let tid = request.threadID
                ?? threadID(from: canonicalURL)
                ?? MangaTitleCleaner.extractTid(from: canonicalURL.absoluteString)
                ?? ""
            let thread = ThreadIdentity(
                tid: tid,
                fid: request.tapContext.containingFid ?? request.threadFid
            )
            let initialPage = await resolvedNativeThreadReaderInitialPage(
                requestURL: requestURL,
                baseInitialPage: baseInitialPage,
                thread: thread,
                title: request.title
            )
            return .thread(
                YamiboThreadRoutePayload(
                    thread: thread,
                    title: request.title ?? L10n.string("forum.default_title"),
                    authorID: request.authorID,
                    canonicalURL: canonicalURL,
                    requestedURL: requestURL,
                    initialPage: initialPage,
                    targetPostID: targetPostID
                )
            )
        }

        let settings = await settingsStore.load().boardReader

        let initialFid = request.tapContext.containingFid ?? request.threadFid
        let initialKind = kindForKnownInputs(
            fid: initialFid,
            knownThreadKind: request.knownThreadKind,
            title: nil,
            settings: settings
        )

        let metadata: YamiboThreadMetadata?
        if shouldFetchMetadata(fid: initialFid, knownThreadKind: request.knownThreadKind, settings: settings) {
            do {
                metadata = try await loadMetadata(for: requestURL)
            } catch let fallback as YamiboThreadRouteResolverWebFallback {
                return .webFallback(fallback.url)
            }
        } else {
            metadata = nil
        }

        let tid = request.threadID
            ?? metadata?.tid
            ?? threadID(from: canonicalURL)
            ?? MangaTitleCleaner.extractTid(from: canonicalURL.absoluteString)
            ?? ""
        let fid = initialFid ?? metadata?.fid
        let title = request.title ?? metadata?.title
        let authorID = request.authorID ?? metadata?.authorID
        let thread = ThreadIdentity(tid: tid, fid: fid)
        let kind = metadata == nil
            ? initialKind
            : kindForKnownInputs(
                fid: fid,
                knownThreadKind: request.knownThreadKind,
                title: [title, metadata?.sectionText].compactMap { $0 }.joined(separator: " "),
                settings: settings
            )

        switch kind {
        case .novel:
            return .novel(
                YamiboThreadRoutePayload(
                    thread: thread,
                    title: title ?? L10n.string("reader.title"),
                    authorID: authorID,
                    canonicalURL: canonicalURL,
                    requestedURL: requestURL,
                    initialPage: baseInitialPage,
                    targetPostID: targetPostID
                )
            )
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
            // unconfigured or missing fid never reports smart-enabled.
            guard settings.isSmartComicModeEnabled(forumID: fid) else {
                return .mangaDirect(payload)
            }
            return .manga(payload)
        case .regular, .unknown:
            let initialPage = try await resolvedThreadReaderInitialPage(
                requestURL: requestURL,
                baseInitialPage: baseInitialPage,
                thread: thread,
                title: title
            )
            return .thread(
                YamiboThreadRoutePayload(
                    thread: thread,
                    title: title ?? L10n.string("forum.default_title"),
                    authorID: authorID,
                    canonicalURL: canonicalURL,
                    requestedURL: requestURL,
                    initialPage: initialPage,
                    targetPostID: targetPostID
                )
            )
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

    private func loadMetadata(for url: URL) async throws -> YamiboThreadMetadata {
        do {
            let html = try await client.fetchHTML(for: .thread(url: url, page: 1, authorID: nil))
            return try YamiboThreadMetadataHTMLParser.parse(from: html, url: url)
        } catch YamiboError.notAuthenticated {
            throw YamiboThreadRouteResolverWebFallback(url: url)
        } catch YamiboError.floodControl {
            throw YamiboThreadRouteResolverWebFallback(url: url)
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
        if let host = url.host, YamiboDomain.containsYamiboDomain(host) {
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

    private func resolvedThreadReaderInitialPage(
        requestURL: URL,
        baseInitialPage: Int,
        thread: ThreadIdentity,
        title: String?
    ) async throws -> Int {
        guard baseInitialPage <= 1, isFindPostURL(requestURL) else {
            return baseInitialPage
        }

        let html = try await client.fetchHTML(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let page = try ForumThreadPageHTMLParser.parsePage(
            from: html,
            thread: thread,
            fallbackTitle: title
        )
        return page.pageNavigation?.currentPage ?? baseInitialPage
    }

    private func resolvedNativeThreadReaderInitialPage(
        requestURL: URL,
        baseInitialPage: Int,
        thread: ThreadIdentity,
        title: String?
    ) async -> Int {
        do {
            return try await resolvedThreadReaderInitialPage(
                requestURL: requestURL,
                baseInitialPage: baseInitialPage,
                thread: thread,
                title: title
            )
        } catch {
            YamiboLog.forum.warning("Failed to resolve native thread reader initial page from findpost lookup, falling back to base page: \(error)")
            return baseInitialPage
        }
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

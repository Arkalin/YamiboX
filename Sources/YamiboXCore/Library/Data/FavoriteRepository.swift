import Foundation

/// One parsed page of the remote favorite list, with page navigation info.
public struct FavoriteRemotePage: Sendable {
    public let favorites: [Favorite]
    public let currentPage: Int
    public let totalPages: Int

    public init(favorites: [Favorite], currentPage: Int, totalPages: Int) {
        self.favorites = favorites
        self.currentPage = max(1, currentPage)
        self.totalPages = max(1, totalPages)
    }
}

/// Remote-only gateway to the Yamibo website's favorite list — every method
/// here is an HTTP operation; none touches the local `FavoriteLibraryStore`.
/// Despite the shared `add`/`delete` word roots, do not confuse these with
/// the UI action layer's local-first orchestration (`FavoriteQuickActions`,
/// which owns the add/import/push/sync terminology glossary).
public actor FavoriteRepository {
    private let client: YamiboClient

    init(client: YamiboClient) {
        self.client = client
    }

    public func fetchFavorites(page: Int = 1) async throws -> [Favorite] {
        let html = try await client.fetchHTML(for: .favorites(page: page))
        let parsed = FavoriteHTMLParser.parseFavoritePage(from: html)
        if parsed.favorites.isEmpty {
            if let error = inferContentError(from: html) {
                throw error
            }
            if !parsed.documentParsed {
                throw YamiboError.parsingFailed(context: L10n.string("context.favorites_page"))
            }
        }
        return parsed.favorites
    }

    public func fetchFavoritesPage(page: Int = 1) async throws -> FavoriteRemotePage {
        let parsed = try await fetchFavoritePage(page: page)
        return FavoriteRemotePage(
            favorites: parsed.favorites,
            currentPage: parsed.currentPage,
            totalPages: parsed.totalPages
        )
    }

    func fetchFavoritePage(page: Int = 1) async throws -> FavoriteHTMLParser.FavoritePageResult {
        let html = try await client.fetchHTML(for: .favorites(page: page))
        let parsed = FavoriteHTMLParser.parseFavoritePage(from: html)
        if parsed.favorites.isEmpty {
            if let error = inferContentError(from: html) {
                throw error
            }
            if !parsed.documentParsed {
                throw YamiboError.parsingFailed(context: L10n.string("context.favorites_page"))
            }
        }
        return parsed
    }

    /// Fetches one page of the remote board-favorite (`type=forum`) list.
    /// Board favorites are network-only — no local store mirrors them — so
    /// callers render this result directly. Deleting one goes through the
    /// shared `deleteFavorite(remoteFavoriteID:)` (the delete endpoint is
    /// `type=all` and works for any favorite kind).
    public func fetchBoardFavoritesPage(page: Int = 1) async throws -> BoardFavoriteRemotePage {
        let html = try await client.fetchHTML(for: .boardFavorites(page: page))
        let parsed = FavoriteHTMLParser.parseBoardFavoritePage(from: html)
        if parsed.boards.isEmpty {
            if let error = inferContentError(from: html) {
                throw error
            }
            if !parsed.documentParsed {
                throw YamiboError.parsingFailed(context: L10n.string("context.board_favorites_page"))
            }
        }
        return BoardFavoriteRemotePage(
            boards: parsed.boards,
            currentPage: parsed.currentPage,
            totalPages: parsed.totalPages
        )
    }

    /// Fetches the session's formHash once so bulk operations (sync upload)
    /// can reuse it instead of re-fetching the profile per request.
    public func currentFormHash() async throws -> String {
        try await ensureFormHash(preferred: nil)
    }

    @discardableResult
    public func addThreadFavorite(
        threadID: String,
        formHash preferredFormHash: String? = nil,
        resolveRemoteFavorite: Bool = true
    ) async throws -> Favorite? {
        guard let tid = threadID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw FavoriteActionError.missingFavoriteThreadID
        }
        let formHash = try await ensureFormHash(preferred: preferredFormHash)
        let responseHTML = try await client.fetchHTML(for: .threadFavorite(tid: tid, formHash: formHash))

        if isLoginPage(responseHTML) {
            throw YamiboError.notAuthenticated
        }
        guard isFavoriteAddSuccess(responseHTML) else {
            throw FavoriteActionError.favoriteAddFailed
        }

        guard resolveRemoteFavorite else { return nil }
        do {
            return try await remoteFavorite(forThreadID: tid)
        } catch {
            YamiboLog.library.warning("Failed to resolve remote favorite id for thread \(tid, privacy: .public) after add succeeded: \(error)")
            return nil
        }
    }

    public func remoteFavorite(forThreadID threadID: String, maxPages: Int = 30) async throws -> Favorite? {
        guard let threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        guard maxPages > 0 else { return nil }
        for page in 1 ... maxPages {
            let html = try await client.fetchHTML(for: .favorites(page: page))
            let parsed = FavoriteHTMLParser.parseFavoritePage(from: html)
            if parsed.favorites.isEmpty {
                if let error = inferContentError(from: html) {
                    throw error
                }
                if !parsed.documentParsed {
                    throw YamiboError.parsingFailed(context: L10n.string("context.favorites_page"))
                }
                return nil
            }
            if let favorite = parsed.favorites.first(where: { $0.threadID == threadID }) {
                return favorite
            }
            if parsed.currentPage >= parsed.totalPages || page >= parsed.totalPages {
                return nil
            }
        }
        return nil
    }

    public func deleteFavorite(remoteFavoriteID: String) async throws {
        let formHTML = try await client.fetchHTML(for: .favoriteDeleteForm, userAgent: YamiboNetworkConfiguration.desktopTagUserAgent)
        if isLoginPage(formHTML) {
            throw YamiboError.notAuthenticated
        }
        guard let formHash = DiscuzFormHashParser.formHash(inHTML: formHTML) else {
            throw FavoriteActionError.missingFavoriteDeleteToken
        }

        let responseHTML = try await client.submitForm(
            for: .favoriteDelete,
            fields: [
                ("formhash", formHash),
                ("delfavorite", "true"),
                ("deletesubmit", "true"),
                ("favorite[]", remoteFavoriteID)
            ],
            userAgent: YamiboNetworkConfiguration.desktopTagUserAgent
        )

        if isLoginPage(responseHTML) {
            throw YamiboError.notAuthenticated
        }
        guard isFavoriteDeleteSuccess(responseHTML) else {
            throw FavoriteActionError.favoriteDeleteFailed
        }
    }

    private func inferContentError(from html: String) -> YamiboError? {
        if isLoginPage(html) {
            return .notAuthenticated
        }
        if isFloodControlOrError(html) {
            return .floodControl
        }
        return nil
    }

    private func isLoginPage(_ html: String) -> Bool {
        let markers = [
            "请先登录",
            "登录后",
            "<title>登录 -",
            "member.php?mod=logging&action=login",
            "id=\"member_login\"",
            "class=\"pg_logging\""
        ]
        return markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

    private func isFloodControlOrError(_ html: String) -> Bool {
        guard !html.contains("没有找到匹配结果") else { return false }
        return html.contains("只能进行一次搜索")
            || html.contains("防灌水")
            || html.contains("指定的搜索词长度")
    }

    private func ensureFormHash(preferred: String?) async throws -> String {
        if let formHash = preferred?.trimmingCharacters(in: .whitespacesAndNewlines),
           !formHash.isEmpty {
            return formHash
        }

        let profileHTML = try await client.fetchHTML(for: .currentProfile)
        if isLoginPage(profileHTML) {
            throw YamiboError.notAuthenticated
        }
        guard let formHash = DiscuzFormHashParser.formHash(inHTML: profileHTML) else {
            throw FavoriteActionError.missingFavoriteAddToken
        }
        return formHash
    }

    private func isFavoriteAddSuccess(_ html: String) -> Bool {
        let markers = [
            "收藏成功",
            "信息收藏成功",
            "已收藏",
            "您已收藏过",
            "succeed",
            "操作成功"
        ]
        return markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

    private func isFavoriteDeleteSuccess(_ html: String) -> Bool {
        let failureMarkers = ["不成功", "失败", "错误"]
        if failureMarkers.contains(where: { html.localizedCaseInsensitiveContains($0) }) {
            return false
        }
        let markers = [
            "成功",
            "succeed",
            "操作成功",
            "收藏删除成功"
        ]
        return markers.contains { html.localizedCaseInsensitiveContains($0) }
    }

}

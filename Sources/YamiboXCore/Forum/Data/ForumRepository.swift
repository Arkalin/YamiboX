import Foundation

public actor ForumRepository {
    private let client: YamiboClient
    private let cacheStore: ForumCacheStore
    private let now: @Sendable () -> Date

    init(
        client: YamiboClient,
        cacheStore: ForumCacheStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.cacheStore = cacheStore
        self.now = now
    }

    public func cachedForumHome(allowExpired: Bool = false) async -> ForumHomePage? {
        await cacheStore.loadHome(allowExpired: allowExpired)
    }

    public func cachedForumBoard(
        fid: String,
        page: Int = 1,
        filterID: String? = nil,
        orderFilter: String? = nil,
        orderBy: String? = nil,
        allowExpired: Bool = false
    ) async -> ForumBoardPage? {
        await cacheStore.loadBoard(
            fid: fid,
            page: page,
            filterID: filterID,
            orderFilter: orderFilter,
            orderBy: orderBy,
            allowExpired: allowExpired
        )
    }

    public func fetchForumHome(preferCache: Bool = true) async throws -> ForumHomePage {
        if preferCache, let cached = await cacheStore.loadHome() {
            return cached
        }

        let html = try await client.fetchHTML(
            for: .forumHome,
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        let page = try ForumHTMLParser.parseHomePage(from: html, fetchedAt: now())
        try await saveHomeCompletingStartedWork(page)
        return page
    }

    public func fetchForumBoard(
        fid: String,
        title: String? = nil,
        page: Int = 1,
        filterID: String? = nil,
        orderFilter: String? = nil,
        orderBy: String? = nil,
        preferCache: Bool = true
    ) async throws -> ForumBoardPage {
        if preferCache,
           let cached = await cacheStore.loadBoard(fid: fid, page: page, filterID: filterID, orderFilter: orderFilter, orderBy: orderBy) {
            return cached
        }

        let html = try await client.fetchHTML(
            for: .forumBoard(fid: fid, page: page, filterID: filterID, orderFilter: orderFilter, orderBy: orderBy),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        let board = try ForumHTMLParser.parseBoardPage(from: html, fid: fid, title: title, fetchedAt: now())
        try await saveBoardCompletingStartedWork(
            board,
            fid: fid,
            pageNumber: page,
            filterID: filterID,
            orderFilter: orderFilter,
            orderBy: orderBy
        )
        return board
    }

    public func addBoardFavorite(fid: String, formHash: String?) async throws -> String {
        guard let formHash = formHash?.trimmingCharacters(in: .whitespacesAndNewlines),
              !formHash.isEmpty else {
            throw FavoriteActionError.missingForumBoardFavoriteToken
        }

        let html = try await client.fetchHTML(
            for: .forumBoardFavorite(fid: fid, formHash: formHash),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return try ForumHTMLParser.parseBoardFavoriteResult(from: html)
    }

    public func searchForum(query: String, forumID: String?, formHash: String?) async throws -> ForumSearchPage {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.forum_search"))
        }
        guard let formHash = formHash?.trimmingCharacters(in: .whitespacesAndNewlines),
              !formHash.isEmpty else {
            throw YamiboError.missingForumSearchToken
        }

        let html = try await client.fetchHTML(
            for: .forumSearch(keyword: normalizedQuery, forumID: forumID, formHash: formHash),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try ForumHTMLParser.parseSearchPage(from: html, query: normalizedQuery)
    }

    public func searchForumPage(query: String, searchID: String, page: Int) async throws -> ForumSearchPage {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSearchID = searchID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, !normalizedSearchID.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.forum_search"))
        }

        let html = try await client.fetchHTML(
            for: .forumSearchPage(searchID: normalizedSearchID, page: page),
            cachePolicy: .reloadIgnoringLocalCacheData,
            cancellationPolicy: .completeStartedRequest
        )
        return try ForumHTMLParser.parseSearchPage(from: html, query: normalizedQuery)
    }

    private func saveHomeCompletingStartedWork(_ page: ForumHomePage) async throws {
        let cacheStore = cacheStore
        let saveTask = Task {
            try await cacheStore.saveHome(page)
        }
        try await saveTask.value
    }

    private func saveBoardCompletingStartedWork(
        _ page: ForumBoardPage,
        fid: String,
        pageNumber: Int,
        filterID: String?,
        orderFilter: String?,
        orderBy: String?
    ) async throws {
        let cacheStore = cacheStore
        let saveTask = Task {
            try await cacheStore.saveBoard(
                page,
                fid: fid,
                pageNumber: pageNumber,
                filterID: filterID,
                orderFilter: orderFilter,
                orderBy: orderBy
            )
        }
        try await saveTask.value
    }
}

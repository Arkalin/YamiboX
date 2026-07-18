import Foundation

enum FavoriteHTMLParser {
    struct FavoritePageResult: Sendable {
        var favorites: [Favorite]
        var currentPage: Int
        var totalPages: Int
        var documentParsed: Bool

        init(favorites: [Favorite], currentPage: Int = 1, totalPages: Int = 1, documentParsed: Bool = true) {
            self.favorites = favorites
            self.currentPage = max(1, currentPage)
            self.totalPages = max(1, totalPages)
            self.documentParsed = documentParsed
        }
    }

    static func parseFavorites(from html: String) -> [Favorite] {
        parseFavoritePage(from: html).favorites
    }

    static func parseFavoritePage(from html: String) -> FavoritePageResult {
        guard let document = try? KannaSoup.parse(html) else {
            return FavoritePageResult(favorites: [], documentParsed: false)
        }
        var favorites: [Favorite] = []
        var seen = Set<String>()

        let selectors = [
            ".sclist li",
            "li.sclist",
            ".fav_list li",
            ".favorite li"
        ]

        for selector in selectors {
            let items = document.select(selector)
            guard !items.isEmpty else { continue }

            for item in items {
                guard let favorite = parseFavorite(from: item, seen: &seen) else { continue }
                favorites.append(favorite)
            }
            return FavoritePageResult(
                favorites: favorites,
                currentPage: parseCurrentPage(in: document),
                totalPages: parseTotalPages(in: document)
            )
        }

        let links = document.select("a[href*='viewthread'], a[href*='thread-']")
        for link in links {
            let href = link.attr("href")
            guard let url = HTMLTextExtractor.absoluteURL(from: href) else { continue }
            guard let threadID = YamiboThreadURLCanonicalizer.threadID(from: url) else { continue }
            let title = link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(threadID).inserted else { continue }
            favorites.append(Favorite(title: title, threadID: threadID))
        }

        return FavoritePageResult(
            favorites: favorites,
            currentPage: parseCurrentPage(in: document),
            totalPages: parseTotalPages(in: document)
        )
    }

    struct BoardFavoritePageResult: Sendable {
        var boards: [BoardFavorite]
        var currentPage: Int
        var totalPages: Int
        var documentParsed: Bool

        init(boards: [BoardFavorite], currentPage: Int = 1, totalPages: Int = 1, documentParsed: Bool = true) {
            self.boards = boards
            self.currentPage = max(1, currentPage)
            self.totalPages = max(1, totalPages)
            self.documentParsed = documentParsed
        }
    }

    /// Parses the `type=forum` variant of the favorite list. Same mobile
    /// template as the thread list (`.sclist li` rows with an `mdel` delete
    /// link carrying the favid), but each row links to a board
    /// (`forumdisplay`/`forum-N-M.html`) instead of a thread.
    static func parseBoardFavoritePage(from html: String) -> BoardFavoritePageResult {
        guard let document = try? KannaSoup.parse(html) else {
            return BoardFavoritePageResult(boards: [], documentParsed: false)
        }
        var boards: [BoardFavorite] = []
        var seen = Set<String>()

        let selectors = [
            ".sclist li",
            "li.sclist",
            ".fav_list li",
            ".favorite li"
        ]

        for selector in selectors {
            let items = document.select(selector)
            guard !items.isEmpty else { continue }

            for item in items {
                guard let board = parseBoardFavorite(from: item, seen: &seen) else { continue }
                boards.append(board)
            }
            return BoardFavoritePageResult(
                boards: boards,
                currentPage: parseCurrentPage(in: document),
                totalPages: parseTotalPages(in: document)
            )
        }

        let links = document.select("a[href*='forumdisplay'], a[href*='forum-']")
        for link in links {
            guard let board = boardFavorite(fromLink: link, remoteFavoriteID: nil, seen: &seen) else { continue }
            boards.append(board)
        }

        return BoardFavoritePageResult(
            boards: boards,
            currentPage: parseCurrentPage(in: document),
            totalPages: parseTotalPages(in: document)
        )
    }

    private static func parseBoardFavorite(from item: Element, seen: inout Set<String>) -> BoardFavorite? {
        guard let link = findBoardLink(in: item) else { return nil }
        return boardFavorite(fromLink: link, remoteFavoriteID: extractRemoteFavoriteID(from: item), seen: &seen)
    }

    private static func boardFavorite(
        fromLink link: Element,
        remoteFavoriteID: String?,
        seen: inout Set<String>
    ) -> BoardFavorite? {
        let href = link.attr("href")
        guard let url = HTMLTextExtractor.absoluteURL(from: href) else { return nil }
        guard let fid = boardID(from: url) else { return nil }

        let title = link.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, seen.insert(fid).inserted else { return nil }

        return BoardFavorite(fid: fid, title: title, remoteFavoriteID: remoteFavoriteID)
    }

    private static func findBoardLink(in item: Element) -> Element? {
        let candidates = item.select("a[href*='forumdisplay'], a[href*='forum-']")
        return candidates.first { element in
            let className = element.className()
            return !className.localizedCaseInsensitiveContains("mdel")
        }
    }

    private static func boardID(from url: URL) -> String? {
        url.queryItemValue("fid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"forum-(\d+)-\d+\.html"#, in: url.absoluteString)?
            .dropFirst()
            .first
    }

    private static func parseFavorite(from item: Element, seen: inout Set<String>) -> Favorite? {
        guard let link = findFavoriteLink(in: item) else { return nil }
        let href = link.attr("href")
        guard let url = HTMLTextExtractor.absoluteURL(from: href) else { return nil }
        guard let threadID = YamiboThreadURLCanonicalizer.threadID(from: url) else { return nil }

        let title = link.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, seen.insert(threadID).inserted else { return nil }

        let remoteFavoriteID = extractRemoteFavoriteID(from: item)
        return Favorite(title: title, threadID: threadID, remoteFavoriteID: remoteFavoriteID)
    }

    private static func findFavoriteLink(in item: Element) -> Element? {
        let candidates = item.select("a[href*='viewthread'], a[href*='thread-']")
        return candidates.first { element in
            let className = element.className()
            return !className.localizedCaseInsensitiveContains("mdel")
        }
    }

    private static func extractRemoteFavoriteID(from item: Element) -> String? {
        let deleteLink = item.select("a.mdel, a[href*='favid=']").first()
        let href = deleteLink?.attr("href") ?? ""
        return HTMLTextExtractor.firstMatch(pattern: #"favid=(\d+)"#, in: href)?.dropFirst().first
    }

    private static func parseCurrentPage(in document: Document) -> Int {
        let currentText = document.select(".pg strong").first()?.text() ?? ""
        return HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: currentText)?
            .dropFirst()
            .first
            .flatMap(Int.init) ?? 1
    }

    private static func parseTotalPages(in document: Document) -> Int {
        guard let pager = document.select(".pg").first() else { return 1 }
        let pagerText = pager.text()
        let explicitTotal = HTMLTextExtractor.firstMatch(pattern: #"共\s*(\d+)\s*页"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)
            ?? HTMLTextExtractor.firstMatch(pattern: #"/\s*(\d+)\s*页"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)
        if let explicitTotal {
            return max(1, explicitTotal)
        }

        let linkedPages = pager.select("a[href*='page=']").array()
            .compactMap { element -> Int? in
                let href = element.attr("href")
                return HTMLTextExtractor.firstMatch(pattern: #"page=(\d+)"#, in: href)?
                    .dropFirst()
                    .first
                    .flatMap(Int.init)
            }
        // On the last page every `page=` link points backwards — never report
        // fewer total pages than the current page.
        return max(1, max(linkedPages.max() ?? 1, parseCurrentPage(in: document)))
    }
}

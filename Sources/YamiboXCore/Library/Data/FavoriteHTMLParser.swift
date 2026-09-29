import Foundation

enum FavoriteHTMLParser {
    struct FavoritePageResult: Sendable {
        var favorites: [Favorite]
        var currentPage: Int
        var totalPages: Int
        var documentParsed: Bool
        var parseStatus: FavoritePageParseStatus

        init(
            favorites: [Favorite],
            currentPage: Int = 1,
            totalPages: Int = 1,
            documentParsed: Bool = true,
            parseStatus: FavoritePageParseStatus? = nil
        ) {
            self.favorites = favorites
            self.currentPage = max(1, currentPage)
            self.totalPages = max(1, totalPages)
            self.documentParsed = documentParsed
            self.parseStatus = parseStatus ?? (documentParsed
                ? (favorites.isEmpty ? .recognizedEmpty : .parsedContent)
                : .failed)
        }
    }

    static func parseFavorites(from html: String) -> [Favorite] {
        parseFavoritePage(from: html).favorites
    }

    static func parseFavoritePage(from html: String) -> FavoritePageResult {
        guard let document = try? KannaSoup.parse(html) else {
            return FavoritePageResult(
                favorites: [], documentParsed: false, parseStatus: .failed
            )
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
            let items = document.select(selector).array()
            guard !items.isEmpty else { continue }

            var malformedRows = false
            for item in items {
                guard let favorite = parseFavorite(from: item) else {
                    malformedRows = true
                    continue
                }
                if seen.insert(favorite.threadID).inserted {
                    favorites.append(favorite)
                }
            }
            if malformedRows {
                // Never turn a partially understood list into an empty,
                // authoritative page. The repository rejects this status so
                // sync cannot mistake it for a valid end-of-pagination page.
                return FavoritePageResult(
                    favorites: [],
                    currentPage: parseCurrentPage(in: document),
                    totalPages: parseTotalPages(in: document),
                    parseStatus: .uncertain
                )
            }
            return FavoritePageResult(
                favorites: favorites,
                currentPage: parseCurrentPage(in: document),
                totalPages: parseTotalPages(in: document),
                parseStatus: .parsedContent
            )
        }

        let links = document.select("a[href*='viewthread'], a[href*='thread-']")
            .array()
            .filter { !isDeleteLink($0) }
        var malformedLinks = false
        for link in links {
            let href = link.attr("href")
            guard let url = HTMLTextExtractor.absoluteURL(from: href),
                  let threadID = YamiboThreadURLCanonicalizer.threadID(from: url) else {
                malformedLinks = true
                continue
            }
            let title = link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                malformedLinks = true
                continue
            }
            guard seen.insert(threadID).inserted else { continue }
            favorites.append(Favorite(title: title, threadID: threadID))
        }

        if malformedLinks {
            return FavoritePageResult(
                favorites: [],
                currentPage: parseCurrentPage(in: document),
                totalPages: parseTotalPages(in: document),
                parseStatus: .uncertain
            )
        }

        let parseStatus: FavoritePageParseStatus
        if !favorites.isEmpty {
            parseStatus = .parsedContent
        } else if isRecognizedEmptyPage(in: document) {
            parseStatus = .recognizedEmpty
        } else {
            parseStatus = .uncertain
        }

        return FavoritePageResult(
            favorites: favorites,
            currentPage: parseCurrentPage(in: document),
            totalPages: parseTotalPages(in: document),
            parseStatus: parseStatus
        )
    }

    struct BoardFavoritePageResult: Sendable {
        var boards: [BoardFavorite]
        var currentPage: Int
        var totalPages: Int
        var documentParsed: Bool

        var parseStatus: FavoritePageParseStatus

        init(
            boards: [BoardFavorite],
            currentPage: Int = 1,
            totalPages: Int = 1,
            documentParsed: Bool = true,
            parseStatus: FavoritePageParseStatus? = nil
        ) {
            self.boards = boards
            self.currentPage = max(1, currentPage)
            self.totalPages = max(1, totalPages)
            self.documentParsed = documentParsed
            self.parseStatus = parseStatus ?? (documentParsed
                ? (boards.isEmpty ? .recognizedEmpty : .parsedContent)
                : .failed)
        }
    }

    /// Parses the `type=forum` variant of the favorite list. Same mobile
    /// template as the thread list (`.sclist li` rows with an `mdel` delete
    /// link carrying the favid), but each row links to a board
    /// (`forumdisplay`/`forum-N-M.html`) instead of a thread.
    static func parseBoardFavoritePage(from html: String) -> BoardFavoritePageResult {
        guard let document = try? KannaSoup.parse(html) else {
            return BoardFavoritePageResult(
                boards: [], documentParsed: false, parseStatus: .failed
            )
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
            let items = document.select(selector).array()
            guard !items.isEmpty else { continue }

            var malformedRows = false
            for item in items {
                let candidates = item.select("a[href*='forumdisplay'], a[href*='forum-']")
                    .array()
                    .filter { !isDeleteLink($0) }
                guard !candidates.isEmpty else {
                    malformedRows = true
                    continue
                }
                guard let board = parseBoardFavorite(from: item) else {
                    malformedRows = true
                    continue
                }
                if seen.insert(board.fid).inserted {
                    boards.append(board)
                }
            }
            if malformedRows || boards.isEmpty {
                return BoardFavoritePageResult(
                    boards: [],
                    currentPage: parseCurrentPage(in: document),
                    totalPages: parseTotalPages(in: document),
                    parseStatus: .uncertain
                )
            }
            return BoardFavoritePageResult(
                boards: boards,
                currentPage: parseCurrentPage(in: document),
                totalPages: parseTotalPages(in: document),
                parseStatus: .parsedContent
            )
        }

        let links = document.select("a[href*='forumdisplay'], a[href*='forum-']")
            .array()
            .filter { !isDeleteLink($0) }
        var malformedLinks = false
        for link in links {
            guard let board = boardFavorite(fromLink: link, remoteFavoriteID: nil) else {
                malformedLinks = true
                continue
            }
            if seen.insert(board.fid).inserted {
                boards.append(board)
            }
        }

        if malformedLinks {
            return BoardFavoritePageResult(
                boards: [],
                currentPage: parseCurrentPage(in: document),
                totalPages: parseTotalPages(in: document),
                parseStatus: .uncertain
            )
        }

        let parseStatus: FavoritePageParseStatus
        if !boards.isEmpty {
            parseStatus = .parsedContent
        } else if isRecognizedEmptyPage(in: document) {
            parseStatus = .recognizedEmpty
        } else {
            parseStatus = .uncertain
        }

        return BoardFavoritePageResult(
            boards: boards,
            currentPage: parseCurrentPage(in: document),
            totalPages: parseTotalPages(in: document),
            parseStatus: parseStatus
        )
    }

    private static func parseBoardFavorite(from item: Element) -> BoardFavorite? {
        guard let link = findBoardLink(in: item) else { return nil }
        return boardFavorite(fromLink: link, remoteFavoriteID: extractRemoteFavoriteID(from: item))
    }

    private static func boardFavorite(
        fromLink link: Element,
        remoteFavoriteID: String?
    ) -> BoardFavorite? {
        let href = link.attr("href")
        guard let url = HTMLTextExtractor.absoluteURL(from: href) else { return nil }
        guard let fid = boardID(from: url) else { return nil }

        let title = link.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        return BoardFavorite(fid: fid, title: title, remoteFavoriteID: remoteFavoriteID)
    }

    private static func findBoardLink(in item: Element) -> Element? {
        let candidates = item.select("a[href*='forumdisplay'], a[href*='forum-']")
        return candidates.first { !isDeleteLink($0) }
    }

    private static func boardID(from url: URL) -> String? {
        url.queryItemValue("fid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"forum-(\d+)-\d+\.html"#, in: url.absoluteString)?
            .dropFirst()
            .first
    }

    private static func parseFavorite(from item: Element) -> Favorite? {
        guard let link = findFavoriteLink(in: item) else { return nil }
        let href = link.attr("href")
        guard let url = HTMLTextExtractor.absoluteURL(from: href) else { return nil }
        guard let threadID = YamiboThreadURLCanonicalizer.threadID(from: url) else { return nil }

        let title = link.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let remoteFavoriteID = extractRemoteFavoriteID(from: item)
        return Favorite(title: title, threadID: threadID, remoteFavoriteID: remoteFavoriteID)
    }

    private static func findFavoriteLink(in item: Element) -> Element? {
        let candidates = item.select("a[href*='viewthread'], a[href*='thread-']")
        return candidates.first { !isDeleteLink($0) }
    }

    private static func extractRemoteFavoriteID(from item: Element) -> String? {
        let deleteLink = item.select("a.mdel, a[href*='favid=']").first()
        let href = deleteLink?.attr("href") ?? ""
        return HTMLTextExtractor.firstMatch(pattern: #"favid=(\d+)"#, in: href)?.dropFirst().first
    }

    private static func isDeleteLink(_ element: Element) -> Bool {
        element.className().localizedCaseInsensitiveContains("mdel")
            || element.attr("href").localizedCaseInsensitiveContains("favid=")
    }

    private static func isRecognizedEmptyPage(in document: Document) -> Bool {
        let pageText = document.text().trimmingCharacters(in: .whitespacesAndNewlines)

        let emptyMarkers = [
            "暂无收藏",
            "沒有收藏",
            "没有收藏",
            "还没有收藏",
            "收藏夹为空",
            "收藏为空",
            "no favorite",
            "no favorites",
            "empty favorites"
        ]
        if emptyMarkers.contains(where: { pageText.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        // Discuz/local-forum variants may keep an empty list shell (often a
        // `.findbox` around an empty `<ul>`) while rendering no message.
        // Only accept an empty shell whose own text is blank or an explicit
        // empty marker; a nonempty unrecognized shell remains uncertain.
        for selector in [".findbox", ".sclist", ".fav_list", ".favorite"] {
            for element in document.select(selector) where element.tagName().lowercased() != "li" {
                guard element.select("li").isEmpty else { continue }
                let text = element.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty || emptyMarkers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                    return true
                }
            }
        }

        return false
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

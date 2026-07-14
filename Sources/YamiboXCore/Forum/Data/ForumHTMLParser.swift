import Foundation

enum ForumHTMLParser {
    static func parseHomePage(from html: String, fetchedAt: Date = .now) throws -> ForumHomePage {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let categories = parseCategories(in: document)
        guard categories.contains(where: { !$0.boards.isEmpty }) else {
            throw YamiboError.parsingFailed(context: L10n.string("context.forum_home"))
        }

        return ForumHomePage(
            categories: categories,
            carouselItems: parseCarouselItems(in: document),
            formHash: parseFormHash(in: document, html: html),
            fetchedAt: fetchedAt
        )
    }

    static func parseBoardPage(
        from html: String,
        fid: String,
        title: String? = nil,
        fetchedAt: Date = .now
    ) throws -> ForumBoardPage {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let documentTitle = document.firstText("title")?
            .replacingOccurrences(of: " -  百合会.*", with: "", options: .regularExpression)
        let headerTitle = document.firstText(".header h2")
        let top = document.selectFirst(".forumdisplay-top")
        let statsText = ((try? top?.select("p").text()) ?? "").htmlNormalized
        let resolvedTitle = title?.nilIfBlank ?? documentTitle
        let board = ForumBoardSummary(
            fid: fid,
            name: headerTitle ?? resolvedTitle?.nilIfBlank ?? L10n.string("forum.board"),
            todayCount: intAfter(label: "今日", in: statsText),
            threadCount: intAfter(label: "主题", in: statsText),
            rank: intAfter(label: "排名", in: statsText),
            iconURL: top?.firstURL("img[src]", attribute: "src"),
            url: ForumRouteResolver.boardURL(fid: fid)
        )
        return ForumBoardPage(
            board: board,
            subBoards: parseSubBoards(in: document),
            pinnedItems: parsePinnedItems(in: document),
            threads: parseThreadSummaries(in: document, fid: fid),
            pageNavigation: parsePageNavigation(in: document),
            filters: parseFilterOptions(in: document),
            orders: parseOrderOptions(in: document),
            formHash: parseFormHash(in: document, html: html),
            fetchedAt: fetchedAt
        )
    }

    static func parseBoardFavoriteResult(from html: String) throws -> String {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let message = document.selectFirst(".jump_c, .alert_info, .messagetext, .showmessage, .wp")?.normalizedText()
            ?? document.body()?.normalizedText()
            ?? ""

        if message.contains("请先登录") || message.contains("請先登錄") || message.contains("请登录") {
            throw YamiboError.notAuthenticated
        }
        if message.contains("失败") || message.contains("失敗") || message.contains("错误") || message.contains("錯誤") {
            throw YamiboError.forumBoardFavoriteFailed
        }
        if message.contains("已收藏") || message.contains("收藏成功") || message.contains("成功收藏") {
            return message
        }

        guard !message.isEmpty else {
            throw YamiboError.forumBoardFavoriteFailed
        }
        return L10n.string("forum.board.favorite_success")
    }

    static func parseSearchPage(from html: String, query: String) throws -> ForumSearchPage {
        try YamiboHTMLPageInspector.ensureReadable(html)

        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let results = parseThreadSummaries(in: document)
        guard !results.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.forum_search"))
        }

        return ForumSearchPage(
            query: query,
            searchID: parseSearchID(in: document, html: html),
            totalCount: parseSearchTotalCount(in: document),
            results: results,
            pageNavigation: parsePageNavigation(in: document)
        )
    }

    private static func parseCategories(in document: Document) -> [ForumCategory] {
        var categories: [ForumCategory] = []
        var seenCategoryIDs = Set<String>()

        for (index, header) in document.selectAll(".forumlist .subforumshow").enumerated() {
            let targetSelector = header.attrText("href") ?? ""
            let title = ((try? header.select("h2").text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let rawID = targetSelector
                .replacingOccurrences(of: "#", with: "")
                .nilIfBlank ?? "category-\(index)"
            let boardsContainer = targetSelector.isEmpty ? nil : document.selectFirst(targetSelector)
            let boards = boardsContainer.map(parseBoards(in:)) ?? []
            guard !boards.isEmpty else { continue }

            let uniqueID = uniqueIdentifier(rawID, seen: &seenCategoryIDs)
            categories.append(ForumCategory(id: uniqueID, title: title, boards: boards))
        }

        return categories
    }

    private static func parseBoards(in container: Element) -> [ForumBoardSummary] {
        var boards: [ForumBoardSummary] = []
        var seenFIDs = Set<String>()

        for row in container.selectAll("li") {
            guard let link = row.selectFirst("a.murl[href*='fid=']")
                ?? row.selectFirst("a[href*='mod=forumdisplay'][href*='fid=']"),
                let url = link.attrURL("href"),
                let fid = forumID(from: url),
                seenFIDs.insert(fid).inserted else {
                continue
            }

            let titleElement = link.selectFirst(".mtit")
            let todayText = ((try? titleElement?.select(".mnum").text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var name = ((try? titleElement?.text()) ?? (try? link.text()) ?? "")
                .replacingOccurrences(of: todayText, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                name = row.selectFirst("img[alt]")?.attrText("alt") ?? ""
            }
            guard !name.isEmpty else { continue }

            let detail = ((try? link.select(".mtxt").text()) ?? "").nilIfBlank
            boards.append(
                ForumBoardSummary(
                    fid: fid,
                    name: name,
                    detail: detail,
                    todayCount: todayCount(from: todayText),
                    iconURL: row.firstURL("img[src]", attribute: "src"),
                    url: url
                )
            )
        }

        return boards
    }

    private static func parseCarouselItems(in document: Document) -> [ForumHomeCarouselItem] {
        var items: [ForumHomeCarouselItem] = []
        var seen = Set<String>()

        for slide in document.selectAll(".yami-swiper .swiper-slide a[href]") {
            guard let targetURL = slide.attrURL("href"),
                  let imageURL = slide.firstURL("img[src]", attribute: "src") else {
                continue
            }
            let item = ForumHomeCarouselItem(
                targetURL: targetURL,
                imageURL: imageURL,
                threadID: threadID(from: targetURL)
            )
            guard seen.insert(item.id).inserted else { continue }
            items.append(item)
        }

        return items
    }

    private static func parseSubBoards(in document: Document) -> [ForumBoardSummary] {
        var boards: [ForumBoardSummary] = []
        var seen = Set<String>()

        for container in document.selectAll(".forumlist .sub-forum") {
            for board in parseBoards(in: container) where seen.insert(board.fid).inserted {
                boards.append(board)
            }
        }

        return boards
    }

    private static func parsePinnedItems(in document: Document) -> [ForumPinnedItem] {
        var items: [ForumPinnedItem] = []
        var seen = Set<String>()

        for row in document.selectAll(".threadlist li.list_top") {
            guard let link = row.selectFirst("a[href]"),
                  let url = link.attrURL("href") else {
                continue
            }

            let marker = link.firstText(".micon") ?? ""
            let title = (link.selectFirst("em") ?? link)
                .normalizedText()
                .replacingOccurrences(of: marker, with: "")
                .htmlNormalized
            guard !title.isEmpty else { continue }

            let threadID = threadID(from: url)
            let kind: ForumPinnedItem.Kind = marker.contains("公告") || url.absoluteString.contains("mod=announcement")
                ? .announcement
                : .thread
            let id = threadID ?? url.absoluteString
            guard seen.insert(id).inserted else { continue }

            items.append(
                ForumPinnedItem(
                    id: id,
                    kind: kind,
                    title: title,
                    url: url,
                    threadID: threadID
                )
            )
        }

        return items
    }

    private static func parseThreadSummaries(in document: Document, fid: String? = nil) -> [ForumThreadSummary] {
        let rows = document.selectAll(".threadlist li.list")
        if !rows.isEmpty {
            return parseThreadRows(rows, fid: fid)
        }

        YamiboLog.forum.warning("parseThreadSummaries: '.threadlist li.list' matched no rows, falling back to generic thread-link scan")
        var summaries: [ForumThreadSummary] = []
        var seen = Set<String>()

        for link in document.selectAll("a[href*='viewthread'][href*='tid='], a[href*='thread-']") {
            let title = ((try? link.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  let url = link.attrURL("href"),
                  let tid = threadID(from: url),
                  seen.insert(tid).inserted else {
                continue
            }
            summaries.append(ForumThreadSummary(tid: tid, title: title, url: url, fid: fid))
        }

        return summaries
    }

    private static func parseThreadRows(_ rows: [Element], fid: String?) -> [ForumThreadSummary] {
        var summaries: [ForumThreadSummary] = []
        var seen = Set<String>()

        for row in rows {
            guard let titleLink = row.selectFirst(".threadlist_tit")?.parent()
                ?? row.selectFirst("a[href*='viewthread']"),
                let url = titleLink.attrURL("href"),
                let tid = threadID(from: url),
                seen.insert(tid).inserted else {
                continue
            }

            let titleContainer = row.selectFirst(".threadlist_tit")
            let marker = ((try? titleContainer?.select(".micon").text()) ?? "").htmlNormalized
            let title = ((titleContainer?.selectFirst("em") ?? titleLink)
                .normalizedText()
                .replacingOccurrences(of: marker, with: ""))
                .htmlNormalized
            guard !title.isEmpty else { continue }

            let authorLink = row.selectFirst(".mmc[href]")
            let authorURL = authorLink?.attrURL("href")
            let footerStats = parseThreadFooter(in: row)

            summaries.append(
                ForumThreadSummary(
                    tid: tid,
                    title: title,
                    url: url,
                    fid: fid,
                    authorName: authorLink?.normalizedText().nilIfBlank,
                    authorID: authorURL.flatMap(userID(from:)),
                    authorAvatarURL: row.firstURL(".mimg img[src]", attribute: "src"),
                    description: row.firstText(".threadlist_mes"),
                    tag: footerStats.tag,
                    isPoll: marker.contains("投票"),
                    replyCount: footerStats.replyCount,
                    viewCount: footerStats.viewCount,
                    lastActivityText: row.firstText(".mtime")
                )
            )
        }

        return summaries
    }

    private static func parseThreadFooter(in row: Element) -> (tag: String?, viewCount: Int?, replyCount: Int?) {
        var tag: String?
        var numbers: [Int] = []

        for item in row.selectAll(".threadlist_foot li") {
            let text = item.normalizedText()
            if text.hasPrefix("#") {
                tag = String(text.dropFirst()).nilIfBlank
            } else if let number = firstInteger(in: text) {
                numbers.append(number)
            }
        }

        return (tag, numbers.first, numbers.dropFirst().first)
    }

    private static func parsePageNavigation(in document: Document) -> ForumPageNavigation? {
        guard let pager = document.selectFirst(".pg") else { return nil }
        let currentPage = pager.firstText("strong").flatMap(Int.init) ?? 1
        let pagerText = pager.normalizedText()
        let totalPages = HTMLTextExtractor.firstMatch(pattern: #"/\s*(\d+)\s*页"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)
            ?? HTMLTextExtractor.firstMatch(pattern: #"\.\.\s*(\d+)"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)

        return ForumPageNavigation(currentPage: currentPage, totalPages: totalPages)
    }

    private static func parseSearchID(in document: Document, html: String) -> String? {
        for link in document.selectAll("a[href*='searchid=']") {
            guard let url = link.attrURL("href"),
                  let searchID = url.queryItemValue("searchid") else {
                continue
            }
            return searchID
        }

        return HTMLTextExtractor.firstMatch(pattern: #"searchid=(\d+)"#, in: html)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func parseSearchTotalCount(in document: Document) -> Int? {
        let text = document.selectFirst(".result, .searchlist, .threadlist_box")?.normalizedText() ?? ""
        guard text.contains("找到") || text.localizedCaseInsensitiveContains("result") else { return nil }
        return firstInteger(in: text)
    }

    private static func parseOrderOptions(in document: Document) -> [ForumOrderOption] {
        var options: [ForumOrderOption] = []
        var seen = Set<String>()

        for link in document.selectAll(".dhnav_box a[href*='forumdisplay']") {
            guard let url = link.attrURL("href") else { continue }
            let title = link.normalizedText()
            guard !title.isEmpty, title != "全部" else { continue }
            let filter = url.queryItemValue("filter")
            let orderBy = url.queryItemValue("orderby")
            let id = orderBy ?? filter ?? title
            guard seen.insert(id).inserted else { continue }
            options.append(ForumOrderOption(id: id, title: title, filter: filter, orderBy: orderBy))
        }

        return options
    }

    private static func parseFilterOptions(in document: Document) -> [ForumFilterOption] {
        var options: [ForumFilterOption] = []
        var seen = Set<String>()

        for link in document.selectAll(".dhnavs_box a[href*='typeid=']") {
            guard let url = link.attrURL("href"),
                  let id = url.queryItemValue("typeid") else {
                continue
            }
            let title = link.normalizedText()
            guard !title.isEmpty, seen.insert(id).inserted else { continue }
            options.append(ForumFilterOption(id: id, title: title))
        }

        return options
    }

    private static func parseFormHash(in document: Document, html: String) -> String? {
        if let value = document.selectFirst("input[name=formhash]")?.attrText("value") {
            return value
        }

        return HTMLTextExtractor.firstMatch(pattern: #"formhash=([A-Za-z0-9]+)"#, in: html)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func forumID(from url: URL) -> String? {
        url.queryItemValue("fid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"forum-(\d+)-\d+\.html"#, in: url.absoluteString)?
            .dropFirst()
            .first
    }

    private static func threadID(from url: URL) -> String? {
        url.queryItemValue("tid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-\d+-\d+\.html"#, in: url.absoluteString)?
            .dropFirst()
            .first
    }

    private static func userID(from url: URL) -> String? {
        url.queryItemValue("uid")
    }

    private static func todayCount(from text: String) -> Int? {
        HTMLTextExtractor.firstMatch(pattern: #"今日\s*(\d+)"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }

    private static func intAfter(label: String, in text: String) -> Int? {
        HTMLTextExtractor.firstMatch(pattern: #"\#(label)\s*[:：]?\s*(\d+)"#, in: text)?
            .dropFirst()
            .last
            .flatMap(Int.init)
    }

    private static func firstInteger(in text: String) -> Int? {
        HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: text)?
            .dropFirst()
            .first
            .flatMap(Int.init)
    }

    private static func uniqueIdentifier(_ candidate: String, seen: inout Set<String>) -> String {
        guard !seen.insert(candidate).inserted else { return candidate }
        var suffix = 2
        while true {
            let next = "\(candidate)-\(suffix)"
            if seen.insert(next).inserted {
                return next
            }
            suffix += 1
        }
    }
}

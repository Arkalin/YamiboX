import Foundation

/// Discuz desktop tag/tag and tag/tagitem templates; mobile templates may omit tags.
enum ForumTagHTMLParser {
    static func parse(_ html: String, target: ForumTagTarget, requestedPage: Int) throws -> ForumTagPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        guard document.selectFirst("#ct h1.mt") != nil,
              document.selectFirst(".taglist, #ct .tl") != nil else {
            throw YamiboError.parsingFailed(context: L10n.string("forum.tags.title"))
        }
        var seenTags = Set<String>()
        let tags = document.selectAll(".taglist a[href]").compactMap { link -> ForumTagSummary? in
            guard let tag = tagSummary(link), seenTags.insert(tag.id).inserted else { return nil }
            return tag
        }
        if target == .index { return ForumTagPage(tags: tags) }

        // Missing names/IDs render a real taglist empty page. Closed tags render a
        // message page and fail the structural guard above instead of appearing empty.
        let tag = document.selectAll("#pt a[href]").compactMap(tagSummary).last
        guard let tag else { return ForumTagPage() }
        var seenThreads = Set<String>()
        let threads = document.selectAll("#ct .tl .bm_c tr").compactMap { row -> ForumThreadSummary? in
            guard let link = row.selectFirst("th a[href]"),
                  let url = link.attrURL("href"), YamiboDomain.isForumURL(url),
                  let tid = YamiboForumURLIdentity.threadID(from: url.absoluteString),
                  let title = link.normalizedText().nilIfBlank, seenThreads.insert(tid).inserted else { return nil }
            let boardLink = row.selectFirst("td.by a[href*='forumdisplay']")
            let authorCell = row.selectAll("td.by").first { $0.selectFirst("cite") != nil }
            let authorLink = authorCell?.selectFirst("cite a[href*='uid=']")
            let fid = boardLink.flatMap { queryValue("fid", in: $0) }
            return ForumThreadSummary(
                tid: tid, title: title, url: url, fid: fid,
                authorName: authorCell?.firstText("cite"),
                authorID: authorLink.flatMap { queryValue("uid", in: $0) },
                tag: boardLink?.normalizedText().nilIfBlank,
                isPoll: row.selectFirst(".fico-vote") != nil,
                replyCount: row.firstText("td.num a").flatMap(Int.init),
                viewCount: row.firstText("td.num em").flatMap(Int.init),
                lastActivityText: row.selectAll("td.by").last?.firstText("em")
            )
        }
        // Desktop's last-page links may only point backwards. Shared userSpace
        // pagination combines explicit totals/link targets and keeps current page.
        let navigation = ForumPageNavigationParser.parse(in: document, template: .userSpace)
            ?? (requestedPage <= 1 ? ForumPageNavigation(currentPage: 1, totalPages: 1) : nil)
        return ForumTagPage(tag: tag, threads: threads, pageNavigation: navigation)
    }

    private static func tagSummary(_ link: Element) -> ForumTagSummary? {
        guard let url = HTMLTextExtractor.absoluteURL(from: link.attr("href")),
              case let .tag(.id(id), _) = ForumRouteResolver.resolve(url: url),
              let name = link.normalizedText().nilIfBlank else { return nil }
        return ForumTagSummary(id: id, name: name)
    }

    private static func queryValue(_ name: String, in link: Element) -> String? {
        URLComponents(string: link.attr("href"))?.queryItems?.first { $0.name == name }?.value?.nilIfBlank
    }
}

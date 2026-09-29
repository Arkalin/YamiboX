import Foundation

/// Supports both Discuz touch and desktop templates, including collapsed bodies.
enum ForumAnnouncementParser {
    static func parse(html: String, url: URL) throws -> ForumPageDocument? {
        let document = try KannaSoup.parse(html, baseURL: url.absoluteString)
        var items: [ForumAnnouncement] = []
        for row in document.select(".annlist > ul > li").array() {
            guard let heading = row.selectFirst("h2 a[id^=ann_]"),
                  let body = row.selectFirst(".annlist_box") else { continue }
            let author = row.selectFirst("h3 a")
            items.append(ForumAnnouncement(
                id: String(heading.id().dropFirst(4)), title: heading.normalizedText(),
                author: author?.normalizedText() ?? "", authorURL: author?.attrURL("href"),
                date: row.selectFirst("h3 .my")?.normalizedText() ?? "",
                blocks: try ForumThreadHTMLBlockParser.parseBlocks(in: body)
            ))
        }
        if items.isEmpty {
            for heading in document.select("[id^=announce][id$=_c]").array() {
                let bodyID = String(heading.id().dropLast(2))
                guard let body = document.selectFirst("div[id=\"\(bodyID)\"]"),
                      let title = heading.selectFirst("h3") else { continue }
                let date = title.selectFirst("em")?.normalizedText() ?? ""
                title.select("em").remove()
                let author = body.selectFirst("p.mbn a")
                let name = author?.normalizedText() ?? ""
                let authorURL = author?.attrURL("href")
                body.select("p.mbn").remove()
                items.append(ForumAnnouncement(
                    id: String(bodyID.dropFirst(8)), title: title.normalizedText(),
                    author: name, authorURL: authorURL, date: date,
                    blocks: try ForumThreadHTMLBlockParser.parseBlocks(in: body)
                ))
            }
        }
        // Explicit server messages (no announcements, permission, login) use
        // the shared status parser rather than an invented empty result.
        guard !items.isEmpty || document.select(".annlist, #annonav").count > 0 else { return nil }
        var seen: Set<URL> = []
        let filters = document.select("#annonav a, #dhnav_li a").array().compactMap { link -> ForumComposerLink? in
            guard let target = link.attrURL("href"),
                  case .announcement = ForumRouteResolver.resolve(url: target),
                  seen.insert(target).inserted else { return nil }
            return ForumComposerLink(title: link.normalizedText(), url: target)
        }
        let selectedID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        var page = ForumPageDocument(url: url, title: L10n.string("forum.board.announcement"))
        page.announcements = ForumAnnouncementPage(items: items, filters: filters, selectedID: selectedID)
        return page
    }
}

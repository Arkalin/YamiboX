import Foundation

private enum Selectors {
    static let threadLink = "a[href*='viewthread'][href*='tid='], a[href*='thread-']"
    static let findPostLink = "a[href*='findpost'][href*='ptid='], a[href*='findpost'][href*='tid=']"
}

private enum Labels {
    static let replyCount = ["回复", "回復"]
    static let viewCount = ["查看", "浏览", "瀏覽"]
}

extension UserSpaceHTMLParser {
    static func parseThreads(from html: String) throws -> UserSpaceThreadPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        return UserSpaceThreadPage(
            threads: parseThreadSummaries(in: document),
            pageNavigation: parsePageNavigation(in: document)
        )
    }

    static func parseReplies(from html: String) throws -> UserSpaceReplyPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var replies: [UserSpaceReplyGroup] = []
        var seen = Set<String>()

        let rows = document.selectAll(".threadlist li.list")
        let containers: [Element] = rows.isEmpty
            ? document.selectAll("\(Selectors.findPostLink), \(Selectors.threadLink)")
                .compactMap(nearestListContainer(for:))
                .deduplicatedByDOMIdentity()
            : rows
        for row in containers {
            guard let link = row.selectFirst(Selectors.findPostLink) ?? row.selectFirst(Selectors.threadLink),
                  let url = link.attrURL("href"),
                  let tid = threadID(from: url) else {
                continue
            }
            let title = firstNonBlank([
                row.firstText(".threadlist_tit em"),
                link.normalizedText().nilIfBlank
            ]) ?? ""
            guard !title.isEmpty else { continue }
            let excerpt = firstNonBlank([
                row.firstText(".quote blockquote"),
                row.firstText("blockquote"),
                row.firstText(".threadlist_mes")
            ])
            guard seen.insert("\(tid)|\(excerpt ?? "")").inserted else { continue }
            replies.append(
                UserSpaceReplyGroup(
                    threadID: tid,
                    threadTitle: title,
                    threadURL: url,
                    excerpt: excerpt,
                    lastActivityText: rowTimeText(in: row)
                )
            )
        }

        return UserSpaceReplyPage(replies: replies, pageNavigation: parsePageNavigation(in: document))
    }

    static func parseBlogs(from html: String) throws -> UserSpaceBlogPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        var blogs: [UserSpaceBlogSummary] = []
        var seen = Set<String>()

        for link in document.selectAll("a[href*='do=blog'][href*='id='], a[href*='blog-']") {
            guard let url = link.attrURL("href"),
                  let blogID = YamiboForumURLIdentity.blogIdentity(from: url)?.blogID,
                  seen.insert(blogID).inserted else {
                continue
            }
            let title = firstNonBlank([
                link.firstText(".threadlist_tit"),
                link.normalizedText().nilIfBlank
            ]) ?? ""
            guard !title.isEmpty else { continue }
            let container = nearestListContainer(for: link)
            blogs.append(
                UserSpaceBlogSummary(
                    blogID: blogID,
                    title: title,
                    url: url,
                    authorName: firstAuthorName(in: container),
                    authorID: firstUserID(in: container),
                    excerpt: firstNonBlank([
                        link.firstText(".threadlist_mes"),
                        container?.firstText(".threadlist_mes")
                    ]),
                    lastActivityText: container.flatMap(rowTimeText(in:)),
                    replyCount: container.flatMap { footCount(in: $0, iconClass: "dm-chat-s-fill") },
                    viewCount: container.flatMap { footCount(in: $0, iconClass: "dm-eye-fill") }
                )
            )
        }

        return UserSpaceBlogPage(blogs: blogs, pageNavigation: parsePageNavigation(in: document))
    }

    private static func parseThreadSummaries(in document: Document) -> [ForumThreadSummary] {
        var threads: [ForumThreadSummary] = []
        var seen = Set<String>()

        for link in document.selectAll(Selectors.threadLink) {
            guard let url = link.attrURL("href"),
                  let tid = threadID(from: url),
                  seen.insert(tid).inserted else {
                continue
            }
            let container = nearestListContainer(for: link)
            let title = firstNonBlank([
                link.firstText(".threadlist_tit em"),
                container?.firstText(".threadlist_tit em"),
                link.normalizedText().nilIfBlank
            ]) ?? ""
            guard !title.isEmpty else { continue }
            threads.append(
                ForumThreadSummary(
                    tid: tid,
                    title: title,
                    url: url,
                    authorName: firstAuthorName(in: container),
                    authorID: firstUserID(in: container),
                    authorAvatarURL: container?.firstURL(
                        anyOf: [".mimg img[src]", "img[src*='avatar']", "img[src]"],
                        attribute: "src"
                    ),
                    description: firstNonBlank([
                        container?.firstText(".threadlist_mes"),
                        container?.normalizedText()
                    ]),
                    replyCount: container.flatMap { footCount(in: $0, iconClass: "dm-chat-s-fill") }
                        ?? legacyCount(labels: Labels.replyCount, in: container),
                    viewCount: container.flatMap { footCount(in: $0, iconClass: "dm-eye-fill") }
                        ?? legacyCount(labels: Labels.viewCount, in: container),
                    lastActivityText: container.flatMap(rowTimeText(in:))
                )
            )
        }

        return threads
    }

    private static func footCount(in row: Element, iconClass: String) -> Int? {
        guard let icon = row.selectFirst("i.\(iconClass)"),
              let cell = icon.parent() else {
            return nil
        }
        return HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: cell.normalizedText())?
            .first
            .flatMap(Int.init)
    }

    private static func legacyCount(labels: [String], in container: Element?) -> Int? {
        guard let text = container?.normalizedText().nilIfBlank else { return nil }
        return intAfterAny(labels: labels, in: text)
    }

    private static func rowTimeText(in row: Element) -> String? {
        firstNonBlank([
            row.firstText(".muser .mtime"),
            row.firstText(".mtime span"),
            row.firstText(".mtime"),
            firstDateText(in: row)
        ])
    }

    private static func firstAuthorName(in element: Element?) -> String? {
        firstNonBlank([
            element?.firstText(".muser .mmc"),
            element?.firstText(".mmc"),
            element?.selectAll("a[href*='uid=']").compactMap { $0.normalizedText().nilIfBlank }.first
        ])
    }

    private static func threadID(from url: URL) -> String? {
        url.queryItemValue("tid")
            ?? url.queryItemValue("ptid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-"#, in: url.absoluteString)?.dropFirst().first
    }
}

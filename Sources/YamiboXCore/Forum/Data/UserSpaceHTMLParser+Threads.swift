import Foundation

/// Selectors repeated across the list parsers in this file. Top-level `private`
/// so the same-named groups in the sibling `UserSpaceHTMLParser+…` files stay
/// strictly file-scoped.
private enum Selectors {
    /// Thread links in both URL forms (query-param and SEO rewrite).
    static let threadLink = "a[href*='viewthread'][href*='tid='], a[href*='thread-']"
}

/// Simplified/traditional pairs of the list-row statistic labels.
private enum Labels {
    static let replyCount = ["回复", "回復"]
    static let viewCount = ["查看", "浏览", "瀏覽"]
}

/// User-space "my content" list pages: own threads, own replies, own blogs.
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

        for link in document.selectAll(Selectors.threadLink) {
            guard let url = link.attrURL("href"),
                  let tid = threadID(from: url),
                  seen.insert(tid).inserted else {
                continue
            }
            let title = link.normalizedText()
            guard !title.isEmpty else { continue }
            let container = nearestListContainer(for: link)
            replies.append(
                UserSpaceReplyGroup(
                    threadID: tid,
                    threadTitle: title,
                    threadURL: url,
                    excerpt: container?.normalizedText().nilIfBlank,
                    lastActivityText: firstDateText(in: container)
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
                  let blogID = blogID(from: url),
                  seen.insert(blogID).inserted else {
                continue
            }
            let title = link.normalizedText()
            guard !title.isEmpty else { continue }
            let container = nearestListContainer(for: link)
            let text = container?.normalizedText() ?? ""
            blogs.append(
                UserSpaceBlogSummary(
                    blogID: blogID,
                    title: title,
                    url: url,
                    authorName: firstAuthorName(in: container),
                    authorID: firstUserID(in: container),
                    excerpt: text.nilIfBlank,
                    lastActivityText: firstDateText(in: container),
                    replyCount: intAfterAny(labels: Labels.replyCount, in: text),
                    viewCount: intAfterAny(labels: Labels.viewCount, in: text)
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
            let title = link.normalizedText()
            guard !title.isEmpty else { continue }
            let container = nearestListContainer(for: link)
            let text = container?.normalizedText() ?? ""
            threads.append(
                ForumThreadSummary(
                    tid: tid,
                    title: title,
                    url: url,
                    authorName: firstAuthorName(in: container),
                    authorID: firstUserID(in: container),
                    authorAvatarURL: container?.firstURL(anyOf: ["img[src*='avatar']", "img[src]"], attribute: "src"),
                    description: text.nilIfBlank,
                    replyCount: intAfterAny(labels: Labels.replyCount, in: text),
                    viewCount: intAfterAny(labels: Labels.viewCount, in: text),
                    lastActivityText: firstDateText(in: container)
                )
            )
        }

        return threads
    }

    private static func firstAuthorName(in element: Element?) -> String? {
        element?.firstText(".mmc, a[href*='uid=']")
    }

    private static func threadID(from url: URL) -> String? {
        url.queryItemValue("tid")
            ?? HTMLTextExtractor.firstMatch(pattern: #"thread-(\d+)-"#, in: url.absoluteString)?.dropFirst().first
    }

    private static func blogID(from url: URL) -> String? {
        url.queryItemValue("id")
            ?? HTMLTextExtractor.firstMatch(pattern: #"blog-(\d+)-"#, in: url.absoluteString)?.dropFirst().first
    }
}

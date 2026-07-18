import Foundation

enum BlogReaderHTMLParser {
    static func parsePage(from html: String, blogID: String, uidHint: String? = nil, titleHint: String? = nil) throws -> BlogReaderPage {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        // Touch template `space_blog_view.htm`: the blog subject lives in
        // `.view_tit` (its leading `em` is the category link); `li.mtit` is the
        // AUTHOR row and must not be mistaken for a title.
        let title = firstNonBlank([
            document.selectFirst(".view_tit").map { element in
                element.ownText().htmlNormalized.nilIfBlank ?? element.normalizedText()
            },
            document.firstText(".blog_tit, .bm_h h1, h1"),
            titleHint,
            document.title().replacingOccurrences(of: "-  百合会", with: "")
        ]) ?? L10n.string("blog_reader.title")
        let root = rootBlogElement(in: document)
        let content = contentElement(in: root, document: document)
        let contentHTML = (content?.html() ?? "").nilIfBlank ?? (root?.html() ?? "")
        let contentText = content?.normalizedText() ?? root?.normalizedText() ?? ""
        let pageText = document.body()?.normalizedText() ?? ""

        guard !contentText.isEmpty else {
            throw YamiboError.parsingFailed(context: L10n.string("context.blog_reader"))
        }

        // View/reply counts render as a bare `<em>` pair after the eye/chat
        // icons in `.authi .mtime .y` — there are no text labels on touch.
        let counterValues = document.selectFirst(".authi .mtime .y")?
            .selectAll("em")
            .compactMap { Int($0.normalizedText()) } ?? []

        return BlogReaderPage(
            blogID: blogID,
            title: title,
            author: author(
                in: document.selectFirst(".authi") ?? root,
                document: document,
                uidHint: uidHint
            ),
            postedAtText: firstNonBlank([
                document.selectFirst(".authi .mtime").map { $0.ownText().htmlNormalized },
                firstDateText(in: root),
                firstDateText(in: document.body())
            ]),
            contentHTML: contentHTML,
            contentText: contentText,
            viewCount: counterValues.first
                ?? intAfterAny(labels: ["查看", "浏览", "瀏覽", "阅读", "閱讀"], in: pageText),
            replyCount: counterValues.dropFirst().first
                ?? intAfterAny(labels: ["回复", "回復", "评论", "評論"], in: pageText),
            collectURL: actionURL(in: document, keywords: ["收藏"]),
            shareURL: actionURL(in: document, keywords: ["分享"]),
            inviteURL: actionURL(in: document, keywords: ["邀请", "邀請"]),
            comments: parseComments(in: document),
            pageNavigation: parsePageNavigation(in: document)
        )
    }

    static func parseCommentResult(from html: String) throws -> String {
        try YamiboHTMLPageInspector.ensureReadable(html)
        let document = try KannaSoup.parse(html, baseURL: YamiboDomain.baseURL.absoluteString)
        let message = document.firstText(".jump_c, .alert_info, .messagetext, .showmessage, .wp, body")

        guard let message else {
            throw YamiboError.parsingFailed(context: L10n.string("context.blog_reader"))
        }
        if message.contains("失败") || message.contains("失敗") || message.contains("错误") || message.contains("錯誤") {
            throw YamiboError.underlying(message)
        }
        return message
    }

    private static func rootBlogElement(in document: Document) -> Element? {
        document.selectFirst(anyOf: [
            "#blog_article",
            ".blog_article",
            ".blogcontent",
            ".blog .content",
            ".vw .d",
            ".postmessage",
            ".message",
            ".bm_c"
        ]) ?? document.body()
    }

    private static func contentElement(in root: Element?, document: Document) -> Element? {
        if let element = root?.selectFirst(anyOf: [".blogcontent", ".blog_article", ".content", ".postmessage", ".message", "td.t_f"]) {
            return element
        }
        return rootBlogElement(in: document)
    }

    private static func parseComments(in document: Document) -> [BlogReaderComment] {
        var comments: [BlogReaderComment] = []
        var seen = Set<String>()

        for container in commentContainers(in: document) {
            let text = container.normalizedText()
            guard !text.isEmpty, !looksLikeRootBlog(container) else { continue }
            let commentID = commentID(in: container)
            let user = author(in: container, document: document, uidHint: nil)
            let content = commentContentElement(in: container) ?? container
            let contentHTML = content.html().nilIfBlank ?? container.html()
            let contentText = content.normalizedText()
            guard !contentText.isEmpty else { continue }
            let key = commentID ?? "\(user.uid ?? "")|\(user.name)|\(contentText)"
            guard seen.insert(key).inserted else { continue }
            comments.append(
                BlogReaderComment(
                    commentID: commentID,
                    author: user,
                    postedAtText: firstDateText(in: container),
                    contentHTML: contentHTML,
                    contentText: contentText,
                    replyURL: replyURL(in: container)
                )
            )
        }

        return comments
    }

    private static func commentContainers(in document: Document) -> [Element] {
        let scoped = document.selectAll("#comment_ul li, .commentlist li, .blog_comment li, li[id^=comment_], dl[id^=comment_], .cmt .ptm, .comment")
        if !scoped.isEmpty {
            return scoped
        }
        YamiboLog.forum.warning("commentContainers: no scoped blog-comment selectors matched, falling back to broad 'li, dl' scan")
        return document.selectAll("li, dl")
    }

    private static func commentContentElement(in container: Element) -> Element? {
        for selector in [".do_comment", ".comment_content", ".content", ".message", ".xg1 + div", "dd", "blockquote"] {
            if let element = container.selectAll(selector).last {
                return element
            }
        }
        return nil
    }

    private static func looksLikeRootBlog(_ element: Element) -> Bool {
        let id = element.attr("id")
        let className = element.className()
        return id.localizedCaseInsensitiveContains("blog_article")
            || className.localizedCaseInsensitiveContains("blog_article")
            || className.localizedCaseInsensitiveContains("blogcontent")
    }

    private static func author(in element: Element?, document: Document, uidHint: String?) -> BlogReaderUser {
        let link = firstUserLink(in: element) ?? firstUserLink(in: document)
        let uid = link?.attrURL("href").flatMap(YamiboForumURLIdentity.userID(from:)) ?? uidHint?.nilIfBlank
        // `.mmc` before any `.muser` scan — the `.muser` wrapper starts before
        // its own `.mmc` child in document order and its text glues the name to
        // the date and action labels.
        let name = firstNonBlank([
            link?.normalizedText(),
            element?.firstText(".mmc, a[id^=author_], .author, .username"),
            document.firstText(".mmc, a[id^=author_], .author, .username")
        ]) ?? L10n.string("user_space.unknown_user")
        let avatarSelectors = ["img[src*='avatar']", ".avatar img[src]", ".mimg img[src]"]
        return BlogReaderUser(
            uid: uid,
            name: name,
            avatarURL: element?.firstURL(anyOf: avatarSelectors + ["img[src]"], attribute: "src")
                ?? document.firstURL(anyOf: avatarSelectors, attribute: "src")
        )
    }

    private static func firstUserLink(in element: Element?) -> Element? {
        element?.selectFirst("a[href*='uid='], a[href*='space-uid-']")
    }

    private static func actionURL(in document: Document, keywords: [String]) -> URL? {
        for link in document.selectAll("a[href]") {
            let text = link.normalizedText()
            guard keywords.contains(where: { text.contains($0) }) else { continue }
            if let url = link.attrURL("href") {
                return url
            }
        }
        return nil
    }

    private static func replyURL(in element: Element) -> URL? {
        for link in element.selectAll("a[href]") {
            let text = link.normalizedText()
            guard text.contains("回复") || text.contains("回復") || text.contains("回覆") else { continue }
            if let url = link.attrURL("href") {
                return url
            }
        }
        return nil
    }

    private static func parsePageNavigation(in document: Document) -> ForumPageNavigation? {
        guard let pager = document.selectFirst(".pg") else { return nil }
        let currentPage = pager.firstText("strong").flatMap(Int.init) ?? 1
        let pagerText = pager.normalizedText()
        let totalPages = HTMLTextExtractor.firstMatch(pattern: #"共\s*(\d+)\s*页"#, in: pagerText)?
            .dropFirst()
            .first
            .flatMap(Int.init)
            ?? HTMLTextExtractor.matches(pattern: #"page=(\d+)"#, in: pager.html())
            .compactMap { $0.dropFirst().first.flatMap(Int.init) }
            .max()
        // On the last page every `page=` link points backwards — never report
        // fewer total pages than the page we are on.
        return ForumPageNavigation(currentPage: currentPage, totalPages: totalPages.map { max($0, currentPage) })
    }

    private static func commentID(in element: Element) -> String? {
        let id = element.attr("id")
        return HTMLTextExtractor.firstMatch(pattern: #"comment[_-]?(\d+)"#, in: id)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func firstDateText(in element: Element?) -> String? {
        let text = element?.normalizedText() ?? ""
        return HTMLTextExtractor.firstMatch(pattern: #"\d{4}[-/]\d{1,2}[-/]\d{1,2}(?:\s+\d{1,2}:\d{2})?"#, in: text)?
            .first?
            .nilIfBlank
    }

    private static func intAfterAny(labels: [String], in text: String) -> Int? {
        for label in labels {
            if let value = HTMLTextExtractor.firstMatch(pattern: #"\#(label)\s*[:：]\s*(\d+)"#, in: text)?
                .dropFirst()
                .last
                .flatMap(Int.init) {
                return value
            }
        }
        return nil
    }

    private static func firstNonBlank(_ values: [String?]) -> String? {
        values.compactMap { $0?.htmlNormalized.nilIfBlank }.first
    }
}

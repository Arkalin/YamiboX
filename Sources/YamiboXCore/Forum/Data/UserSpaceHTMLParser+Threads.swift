import Foundation

/// Selectors repeated across the list parsers in this file. Top-level `private`
/// so the same-named groups in the sibling `UserSpaceHTMLParser+…` files stay
/// strictly file-scoped.
private enum Selectors {
    /// Thread links in both URL forms (query-param and SEO rewrite).
    static let threadLink = "a[href*='viewthread'][href*='tid='], a[href*='thread-']"
    /// Reply rows link through the redirect/findpost form instead.
    static let findPostLink = "a[href*='findpost'][href*='ptid='], a[href*='findpost'][href*='tid=']"
}

/// Simplified/traditional pairs of the list-row statistic labels (legacy
/// text-labelled shapes only — the touch template uses icons, see below).
private enum Labels {
    static let replyCount = ["回复", "回復"]
    static let viewCount = ["查看", "浏览", "瀏覽"]
}

/// User-space "my content" list pages (touch templates `space_thread.htm` /
/// `space_blog_list.htm`): own threads, own replies, own blogs.
///
/// Touch row shape shared by these lists:
/// ```html
/// <li class="list">
///   <div class="threadlist_top cl">
///     <a href="home.php?mod=space&uid=N" class="mimg"><img …></a>
///     <div class="muser"><h3><a … class="mmc">AUTHOR</a></h3><span class="mtime">TIME</span></div>
///   </div>
///   <a href="…"><div class="threadlist_tit cl"><span class="micon">投票</span><em>SUBJECT</em></div></a>
///   <a href="…"><div class="threadlist_mes cl">EXCERPT</div></a>
///   <div class="threadlist_foot cl"><ul>
///     <li class="mr"><a>#FORUM</a></li>
///     <li><i class="dm-eye-fill"></i>VIEWS</li>
///     <li><i class="dm-chat-s-fill"></i>REPLIES</li>
///   </ul></div>
/// </li>
/// ```
/// Times are `date(…,'u')` output — relative phrases for recent items — and are
/// kept verbatim. Counts hang off the foot icons, never off text labels.
/// Reply rows (`type=reply`) link via `mod=redirect&goto=findpost&ptid=…&pid=…`
/// with the quoted own reply in a `.quote blockquote` block.
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
                  let blogID = blogID(from: url),
                  seen.insert(blogID).inserted else {
                continue
            }
            // The touch blog row wraps title AND excerpt in one anchor —
            // scope each to its own node before falling back to the link text.
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

    /// Count next to a `.threadlist_foot` icon (`<i class="dm-eye-fill"></i>300`).
    private static func footCount(in row: Element, iconClass: String) -> Int? {
        guard let icon = row.selectFirst("i.\(iconClass)"),
              let cell = icon.parent() else {
            return nil
        }
        return HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: cell.normalizedText())?
            .first
            .flatMap(Int.init)
    }

    /// Legacy text-labelled counts ("回复: 12") for non-touch page shapes.
    private static func legacyCount(labels: [String], in container: Element?) -> Int? {
        guard let text = container?.normalizedText().nilIfBlank else { return nil }
        return intAfterAny(labels: labels, in: text)
    }

    /// Row timestamp, kept verbatim — recent items render as relative phrases
    /// ("昨天 22:11", "3 天前") that the absolute-date regex cannot see.
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

    private static func blogID(from url: URL) -> String? {
        url.queryItemValue("id")
            ?? HTMLTextExtractor.firstMatch(pattern: #"blog-(\d+)-"#, in: url.absoluteString)?.dropFirst().first
    }
}

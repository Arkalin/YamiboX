import Foundation

/// Locates post containers on a thread page and assembles each into a `ForumThreadPost`:
/// structural navigation (container, body, floor, author, timestamps, manage actions)
/// plus delegation to the poll/rating/comment/attachment part parsers and the
/// content-block pipeline.
enum ForumThreadPostsParser {
    static func posts(in document: Document) throws -> [ForumThreadPost] {
        let containers = postContainers(in: document)
        var seen: Set<String> = []
        var posts: [ForumThreadPost] = []

        for container in containers {
            guard let body = postBody(in: container),
                  let postID = postID(from: container, body: body),
                  seen.insert(postID).inserted else {
                continue
            }

            let lastEditedText = lastEditedText(in: container, body: body)
            let poll = ForumThreadPollParser.poll(in: container, body: body)
            let ratingBlock = ForumThreadRatingParser.ratingBlock(in: container, postID: postID)
            let comments = try ForumThreadCommentParser.comments(in: container, postID: postID)
            let attachments = ForumThreadAttachmentParser.footerAttachments(in: container, body: body)
            let manageActions = manageActions(in: container)
            let contentBody = try bodyWithoutFooterMetadata(from: body)
            let contentHTML = contentBody.html()
            let images = postImages(in: contentBody, container: container)
            let contentBlocks = try ForumThreadHTMLBlockParser.parseBlocks(in: contentBody)
            let contentText = normalizedBodyText(from: contentBlocks)
            guard !contentText.isEmpty
                || contentBlocks.contains(where: \.isNonTextRenderable)
                || !images.isEmpty
                || poll != nil
                || ratingBlock != nil
                || !comments.isEmpty
                || !attachments.isEmpty
            else {
                continue
            }

            posts.append(
                ForumThreadPost(
                    postID: postID,
                    floorText: floorText(in: container),
                    author: author(in: container),
                    postedAtText: postedAtText(in: container),
                    lastEditedText: lastEditedText,
                    contentHTML: contentHTML,
                    contentText: contentText,
                    contentBlocks: contentBlocks,
                    images: images,
                    poll: poll,
                    ratingBlock: ratingBlock,
                    comments: comments,
                    attachments: attachments,
                    isPinned: isPinned(container),
                    manageActions: manageActions
                )
            )
        }

        return posts
    }

    private static func postContainers(in document: Document) -> [Element] {
        let explicit = document
            .selectAll("[id^=post_], [id^=pid]")
            .filter { element in
                postBody(in: element) != nil
            }
        if !explicit.isEmpty {
            return explicit
        }

        YamiboLog.forum.warning("postContainers: primary '[id^=post_], [id^=pid]' scan yielded no resolvable-body elements, falling back to broad '.message, [id^=postmessage_]' scan")
        return document.selectAll(".message, [id^=postmessage_]")
    }

    private static func postBody(in container: Element) -> Element? {
        if isPostBody(container) {
            return container
        }
        return container.selectFirst(".message, [id^=postmessage_], .t_f")
    }

    private static func isPostBody(_ element: Element) -> Bool {
        let rawID = element.id().trimmingCharacters(in: .whitespacesAndNewlines)
        return element.hasClass("message") || rawID.hasPrefix("postmessage_")
    }

    private static func postID(from container: Element, body: Element) -> String? {
        for element in [container, body] {
            let rawID = element.id().trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = postID(fromRawID: rawID, prefix: "post_") {
                return value
            }
            if let value = postID(fromRawID: rawID, prefix: "pid") {
                return value
            }
            if let value = postID(fromRawID: rawID, prefix: "postmessage_") {
                return value
            }
        }

        return nil
    }

    private static func postID(fromRawID rawID: String, prefix: String) -> String? {
        guard rawID.hasPrefix(prefix) else { return nil }
        return String(rawID.dropFirst(prefix.count)).nilIfBlank
    }

    private static func author(in container: Element) -> BlogReaderUser {
        let link = container.selectFirst(anyOf: [
            ".authi a[href*='uid=']",
            ".authi a[href*='space-uid-']",
            "a.author",
            ".mtit a[href*='uid=']"
        ])
        let name = link?.normalizedText().nilIfBlank
            ?? L10n.string("forum.thread.unknown_author")
        let uid = link.flatMap { ForumUserIDParser.userID(fromHref: $0.attr("href")) }
        return BlogReaderUser(uid: uid, name: name, avatarURL: container.firstURL("img[src]", attribute: "src"))
    }

    private static func floorText(in container: Element) -> String? {
        let raw = [
            container.selectFirst(".authi em[title]")?.attrText("title") ?? "",
            container.firstText(".authi em") ?? "",
            container.firstText(".mtit .y") ?? "",
            container.firstText(".floor, .xg1") ?? ""
        ]
            .joined(separator: " ")
        return HTMLTextExtractor.firstMatch(pattern: #"(\d+\s*#|楼主|樓主)"#, in: raw)?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func postedAtText(in container: Element) -> String? {
        // Desktop-style markup prefixes the date with "发表于"/"發表於" inside `.authi`.
        let prefixedText = container.selectFirst(".authi")?.normalizedText() ?? ""
        if let prefixed = HTMLTextExtractor.firstMatch(pattern: #"(发表于|發表於)\s*([^|#]+)"#, in: prefixedText)?
            .dropFirst()
            .dropFirst()
            .first?
            .nilIfBlank {
            return prefixed
        }

        // The mobile Discuz theme (what the app actually requests — see
        // YamiboNetworkConfiguration.defaultMobileUserAgent) has no such prefix:
        // `.mtime` holds a bare date/relative-time string, occasionally preceded
        // by concatenated view/reply-count digits on the thread's first floor
        // (e.g. "189623" immediately before "2026-7-5 11:49"), so pull out just
        // the date/relative-time shape rather than trusting the whole node text.
        // Scoped to `.authi .mtime` (not the whole container) so a coincidental
        // "mtime"-classed element inside a quoted reply body can't be picked up.
        let mtimeText = container.firstText(".authi .mtime") ?? ""
        return HTMLTextExtractor.firstMatch(
            pattern: #"(\d{4}[-/]\d{1,2}[-/]\d{1,2}(?:\s+\d{1,2}:\d{2})?|昨天\s*\d{1,2}:\d{2}|前天\s*\d{1,2}:\d{2}|刚刚|\d+\s*(?:秒|分钟|小时|天)前)"#,
            in: mtimeText
        )?
            .dropFirst()
            .first?
            .nilIfBlank
    }

    private static func isPinned(_ container: Element) -> Bool {
        // Touch template marks stuck replies with a `settop.png` icon in the
        // floor cell — there is no "置顶" text on the row itself.
        if container.selectFirst("img[src*='settop']") != nil {
            return true
        }
        let text = container.normalizedText()
        if text.contains("置顶") || text.contains("置頂") {
            return true
        }
        let classAndTitle = [
            container.className(),
            container.selectAll("[title]").map { $0.attr("title") }.joined(separator: " "),
            container.selectAll("[class]").map { $0.className() }.joined(separator: " ")
        ].joined(separator: " ").lowercased()
        return classAndTitle.contains("pin")
            || classAndTitle.contains("stick")
            || classAndTitle.contains("digest")
    }

    private static func manageActions(in container: Element) -> [ForumThreadManageAction] {
        var seen: Set<String> = []
        var actions: [ForumThreadManageAction] = []
        for link in container.selectAll("a[href]") {
            let rawTitle = link.normalizedText().nilIfBlank ?? link.attrText("title")
            guard let rawTitle,
                  !isInsideCommentList(link),
                  isManageActionLink(link, title: rawTitle),
                  let url = link.attrURL("href") else {
                continue
            }
            let action = ForumThreadManageAction(title: rawTitle, url: url)
            if seen.insert(action.id).inserted {
                actions.append(action)
            }
        }
        // The touch manage popup renders most actions as `<input … href="…">`
        // buttons (only 编辑 is an `<a>`); titles live in the `value` attribute.
        for input in container.selectAll(".manage input[href], .manage_popup input[href]") {
            guard let rawTitle = input.attrText("value") ?? input.attrText("title"),
                  !isInsideCommentList(input),
                  isManageActionLink(input, title: rawTitle),
                  let url = input.attrURL("href") else {
                continue
            }
            let action = ForumThreadManageAction(title: rawTitle, url: url)
            if seen.insert(action.id).inserted {
                actions.append(action)
            }
        }
        return actions
    }

    /// The inline 点评 list carries its own moderator delete links — those are
    /// comment actions, not post manage actions.
    private static func isInsideCommentList(_ element: Element) -> Bool {
        element.parents().contains { $0.id().hasPrefix("comment_") || $0.id().hasPrefix("commentdetail_") }
    }

    private static func isManageActionLink(_ link: Element, title: String) -> Bool {
        guard isManageActionTitle(title) else { return false }
        let href = link.attr("href").lowercased()
        if href.contains("modcp")
            || href.contains("topicadmin")
            || href.contains("action=moderate")
            || href.contains("action=edit")
            || href.contains("action=delpost")
            || href.contains("action=warn") {
            return true
        }

        let parentClassTokens = Set(
            link.parents()
                .flatMap { $0.className().lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }
        )
        return !parentClassTokens.isDisjoint(with: ["po", "pob", "manage", "postmanage"])
    }

    private static func isManageActionTitle(_ title: String) -> Bool {
        let normalized = title.htmlNormalized
        let allowed = [
            "管理",
            "编辑",
            "編輯",
            "删除",
            "刪除",
            "评分",
            "評分",
            "警告",
            "屏蔽",
            "置顶",
            "置頂",
            "精华",
            "精華",
            "提升",
            "下沉"
        ]
        return allowed.contains { normalized.contains($0) }
    }

    private static func lastEditedText(in container: Element, body: Element) -> String? {
        let selectors = [
            ".pstatus",
            ".lastedit",
            ".editinfo",
            ".edited"
        ]
        for selector in selectors {
            for element in body.selectAll(selector) + container.selectAll(selector) {
                if let text = element.normalizedText().nilIfBlank {
                    return text
                }
            }
        }

        let bodyText = body.text()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return DiscuzEditedDateParser.firstEditedNote(in: bodyText)
    }

    /// A detached copy of the post body with footer metadata (edit status, rating log,
    /// comments, polls) removed, so the content pipeline only sees the message itself.
    private static func bodyWithoutFooterMetadata(from body: Element) throws -> Element {
        let document = try KannaSoup.parseBodyFragment(body.html(), baseURL: YamiboDomain.baseURL.absoluteString)
        let copy = document.body() ?? document
        copy.select(
            [
                ".pstatus",
                ".lastedit",
                ".editinfo",
                ".edited",
                "[id^=ratelog_]",
                ".ratelog",
                ".ratl",
                ".cm",
                "[id^=comment_]",
                ".pcht",
                ".poll",
                "#poll",
                ".polls"
            ].joined(separator: ", ")
        ).remove()
        return copy
    }

    private static func postImages(in body: Element, container: Element) -> [ForumThreadPostImage] {
        let imageElements = body.selectAll("img") + container.selectAll(".img_one img")
        return imageElements.compactMap { image in
            guard let source = YamiboImageReferenceExtractor.forumPostImage.rawReference(from: image) else {
                return nil
            }
            return ForumThreadPostImage(
                url: source,
                altText: image.attr("alt")
            )
        }
    }

    private static func normalizedBodyText(from blocks: [ForumThreadContentBlock]) -> String {
        let text = blocks.flatMap(\.plainTextFragments).joined(separator: "\n")
        return ForumThreadHTMLBlockParser.normalizeCommittedText(text)
    }
}

private extension ForumThreadContentBlock {
    var isNonTextRenderable: Bool {
        switch kind {
        case .image, .attachment, .horizontalRule, .table:
            true
        case let .quote(blocks), let .collapse(_, blocks), let .locked(_, blocks):
            blocks.contains(where: \.isNonTextRenderable) || !plainTextFragments.isEmpty
        case .text, .code:
            false
        }
    }

    var plainTextFragments: [String] {
        switch kind {
        case let .text(block):
            [block.text]
        case let .attachment(block):
            [block.fileName]
        case let .quote(blocks), let .collapse(_, blocks), let .locked(_, blocks):
            blocks.flatMap(\.plainTextFragments)
        case let .code(text):
            [text]
        case let .table(rows):
            rows.flatMap { row in row.flatMap { cell in cell.blocks.flatMap(\.plainTextFragments) } }
        case .image, .horizontalRule:
            []
        }
    }
}

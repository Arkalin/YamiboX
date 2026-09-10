import Foundation

enum ChapterCommentsHTMLParser {
    private static let filteredRatingReasons: Set<String> = [
        "你太可爱",
        "你太可愛",
        "好萌好萌好萌",
        "我很赞同",
        "我很贊同",
        "精品文章",
        "原创内容",
        "原創內容"
    ]

    static func parseInitialPage(
        html: String,
        target: ReaderChapterCommentTarget
    ) throws -> ChapterCommentsPage {
        let document = try KannaSoup.parse(html)
        var comments: [ChapterComment] = []
        comments.append(contentsOf: try postComments(in: document, target: target))
        comments.append(contentsOf: try ratingReasons(in: document, target: target))
        let replies = try samePageReplies(in: document, target: target)
        comments.append(contentsOf: replies.comments)
        return ChapterCommentsPage(
            target: target,
            comments: comments,
            isBoundaryClosed: replies.isBoundaryClosed,
            nextView: nextView(in: document, target: target, currentView: target.view, isBoundaryClosed: replies.isBoundaryClosed)
        )
    }

    static func parseContinuationPage(
        html: String,
        target: ReaderChapterCommentTarget,
        view: Int
    ) throws -> ChapterCommentsPage {
        let document = try KannaSoup.parse(html)
        let replies = try continuationReplies(in: document, target: target)
        return ChapterCommentsPage(
            target: target,
            comments: replies.comments,
            isBoundaryClosed: replies.isBoundaryClosed,
            nextView: nextView(in: document, target: target, currentView: view, isBoundaryClosed: replies.isBoundaryClosed)
        )
    }

    static func currentView(html: String, fallback: Int) throws -> Int {
        let document = try KannaSoup.parse(html)
        return document.firstText(".pg strong").flatMap(Int.init) ?? max(1, fallback)
    }

    static func fullRatingReasonsURL(
        html: String,
        target: ReaderChapterCommentTarget
    ) throws -> URL? {
        let document = try KannaSoup.parse(html)
        return document.firstURL("[id=ratelog_\(target.ownerPostID)] a[href*=action=viewratings]")
    }

    static func parseFullRatingReasonsPage(
        html: String,
        target: ReaderChapterCommentTarget
    ) throws -> [ChapterComment] {
        let document = try KannaSoup.parse(html)
        let rows = document.select(".post_box li.flex-box").array()
        var comments: [ChapterComment] = []
        var pending: (author: String, metadata: String?)?

        for row in rows {
            let values = row.select("span.z, span.y").array().map { normalizeText($0.text()) }
            if values.count >= 3, values[0].contains("积分") {
                pending = (
                    author: values[1],
                    metadata: nilIfEmpty([values[0], values[2]].joined(separator: " · "))
                )
                continue
            }

            let bodyBlocks = try emoticonBodyBlocks(in: row.select("span.z, span.y").first())
            guard let current = pending,
                  let reason = values.first.map(normalizeRatingReason),
                  bodyBlocks != nil || (!reason.isEmpty && !filteredRatingReasons.contains(reason)) else {
                pending = nil
                continue
            }
            comments.append(
                ChapterComment(
                    id: "\(target.ownerPostID):rating-full:\(comments.count)",
                    source: .ratingReason,
                    authorName: normalizeText(current.author),
                    metadata: current.metadata,
                    body: reason,
                    postID: target.ownerPostID,
                    bodyBlocks: bodyBlocks
                )
            )
            pending = nil
        }

        return comments
    }

    private static func postComments(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> [ChapterComment] {
        let rows = document.select("#comment_\(target.ownerPostID) .pstl")
        var comments: [ChapterComment] = try rows.array().enumerated().compactMap { offset, row in
            let author = row.select(".psta a.xi2, .psta a.xw1, .psta a").first()?.text() ?? ""
            guard let bodyElement = row.select(".psti").first() else { return nil }
            let metadata = bodyElement.select(".xg1").first()?.text()
            bodyElement.select(".xg1").remove()
            let body = normalizeText(bodyElement.text())
            let bodyBlocks = try emoticonBodyBlocks(in: bodyElement)
            guard !body.isEmpty || bodyBlocks != nil else { return nil }
            return ChapterComment(
                id: "\(target.ownerPostID):comment:\(offset)",
                source: .postComment,
                authorName: normalizeText(author),
                metadata: nilIfEmpty(normalizeText(metadata ?? "")),
                body: body,
                postID: target.ownerPostID,
                bodyBlocks: bodyBlocks
            )
        }
        comments.append(contentsOf: try mobilePostComments(in: document, target: target))
        return comments
    }

    private static func ratingReasons(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> [ChapterComment] {
        let rows = document.select("[id=ratelog_\(target.ownerPostID)] tr")
        var comments: [ChapterComment] = try rows.array().enumerated().compactMap { offset, row in
            let cells = row.select("td")
            let author = cells.first()?.select("a").last()?.text() ?? ""
            let reason = normalizeRatingReason(row.select("td.xg1").first()?.text() ?? "")
            let bodyBlocks = try emoticonBodyBlocks(in: row.select("td.xg1").first())
            guard bodyBlocks != nil || (!reason.isEmpty && !filteredRatingReasons.contains(reason)) else {
                return nil
            }
            return ChapterComment(
                id: "\(target.ownerPostID):rating:\(offset)",
                source: .ratingReason,
                authorName: normalizeText(author),
                body: reason,
                postID: target.ownerPostID,
                bodyBlocks: bodyBlocks
            )
        }
        comments.append(contentsOf: try mobileRatingReasons(in: document, target: target))
        return comments
    }

    private static func mobilePostComments(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> [ChapterComment] {
        let rows = document.select("[id=comment_\(target.ownerPostID)] [id^=commentdetail_]")
        return try rows.array().enumerated().compactMap { offset, row in
            let author = row.select("a").first()?.text() ?? ""
            let metadata = row.select(".mtime").first()?.text()
            let body = normalizeText(row.select(".mtxt").first()?.text() ?? "")
            let bodyBlocks = try emoticonBodyBlocks(in: row.select(".mtxt").first())
            guard !body.isEmpty || bodyBlocks != nil else { return nil }
            return ChapterComment(
                id: "\(target.ownerPostID):comment-mobile:\(offset)",
                source: .postComment,
                authorName: normalizeText(author),
                metadata: nilIfEmpty(normalizeText(metadata ?? "")),
                body: body,
                postID: target.ownerPostID,
                bodyBlocks: bodyBlocks
            )
        }
    }

    private static func mobileRatingReasons(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> [ChapterComment] {
        let rows = document.select("[id=ratelog_\(target.ownerPostID)] li.flex-box")
        return try rows.array().enumerated().compactMap { offset, row in
            let cells = row.children().array()
            guard cells.count >= 3 else { return nil }
            let author = cells[0].select("a").last()?.text() ?? ""
            let reason = normalizeRatingReason(cells[2].text())
            let bodyBlocks = try emoticonBodyBlocks(in: cells[2])
            guard reason != "理由",
                  bodyBlocks != nil || (!reason.isEmpty && !filteredRatingReasons.contains(reason)) else {
                return nil
            }
            return ChapterComment(
                id: "\(target.ownerPostID):rating-mobile:\(offset)",
                source: .ratingReason,
                authorName: normalizeText(author),
                body: reason,
                postID: target.ownerPostID,
                bodyBlocks: bodyBlocks
            )
        }
    }

    private static func samePageReplies(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> (comments: [ChapterComment], isBoundaryClosed: Bool) {
        let messageNodes = replyMessageNodes(in: document)
        var foundTarget = false
        var comments: [ChapterComment] = []

        for message in messageNodes {
            guard let postID = postID(from: message) else { continue }
            if postID == target.ownerPostID {
                foundTarget = true
                continue
            }
            guard foundTarget else { continue }

            if isOwnerPost(message, target: target) {
                return (comments, true)
            }

            guard let body = try replyBody(from: message) else {
                continue
            }
            comments.append(
                ChapterComment(
                    id: "\(target.ownerPostID):reply:\(postID)",
                    source: .reply,
                    authorName: authorName(for: message),
                    metadata: replyMetadata(for: message),
                    body: body.text,
                    postID: postID,
                    bodyBlocks: body.blocks
                )
            )
        }

        return (comments, false)
    }

    private static func continuationReplies(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> (comments: [ChapterComment], isBoundaryClosed: Bool) {
        let messageNodes = replyMessageNodes(in: document)
        var comments: [ChapterComment] = []

        for message in messageNodes {
            guard let postID = postID(from: message) else { continue }
            if isOwnerPost(message, target: target) {
                return (comments, true)
            }
            guard let body = try replyBody(from: message) else {
                continue
            }
            comments.append(
                ChapterComment(
                    id: "\(target.ownerPostID):reply:\(postID)",
                    source: .reply,
                    authorName: authorName(for: message),
                    metadata: replyMetadata(for: message),
                    body: body.text,
                    postID: postID,
                    bodyBlocks: body.blocks
                )
            )
        }

        return (comments, false)
    }

    private static func replyMessageNodes(in document: Document) -> [Element] {
        let nodes = document.select(".message, [id^=postmessage_]").array()
        var uniqueNodes: [Element] = []
        for node in nodes {
            if !isPostMessageElement(node),
               !node.select("[id^=postmessage_]").isEmpty {
                continue
            }
            if uniqueNodes.contains(where: { $0.isSameDOMNode(as: node) }) {
                continue
            }
            uniqueNodes.append(node)
        }
        return uniqueNodes
    }

    private static func replyBody(from message: Element) throws -> (text: String, blocks: [ForumThreadTextBlock]?)? {
        let fragment = try KannaSoup.parseBodyFragment(message.html())
        guard let body = fragment.body() else { return nil }
        body.select(".quote, blockquote, i, .pstatus").remove()
        let text = normalizeText(body.text())
        let blocks = try emoticonBodyBlocks(in: body)
        return text.isEmpty && blocks == nil ? nil : (text, blocks)
    }

    private static func emoticonBodyBlocks(in element: Element?) throws -> [ForumThreadTextBlock]? {
        guard let element,
              element.select("img").array().contains(where: { image in
                  YamiboImageReferenceExtractor.forumContent.url(from: image)
                      .map(YamiboImageReferenceExtractor.isEmoticonURL) == true
              }) else { return nil }
        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(in: element).flatMap(commentTextBlocks)
        return blocks.contains(where: { !$0.inlineImages.isEmpty }) ? blocks : nil
    }

    // Comments remain text-only apart from smileys; do not introduce photo or
    // attachment previews, or forum-specific styling, into the reader sheet.
    private static func commentTextBlocks(_ block: ForumThreadContentBlock) -> [ForumThreadTextBlock] {
        switch block.kind {
        case let .text(text):
            [ForumThreadTextBlock(text: text.text, inlineImages: text.inlineImages)]
        case let .quote(blocks), let .collapse(_, blocks), let .locked(_, blocks):
            blocks.flatMap(commentTextBlocks)
        case let .table(rows):
            rows.flatMap { $0.flatMap { $0.blocks.flatMap(commentTextBlocks) } }
        case let .code(text):
            [ForumThreadTextBlock(text: text)]
        case .image, .attachment, .horizontalRule:
            []
        }
    }

    private static func isOwnerPost(_ message: Element, target: ReaderChapterCommentTarget) -> Bool {
        guard let container = postContainer(for: message) else {
            return false
        }
        if !container.select("[title=楼主]").isEmpty {
            return true
        }
        if let authorID = target.authorID,
           authorUID(for: container) == authorID {
            return true
        }
        return false
    }

    private static func authorName(for message: Element) -> String {
        guard let container = postContainer(for: message) else {
            return ""
        }
        return container.firstText(anyOf: [
            ".authi .author",
            ".authi a[href*=space-uid]",
            ".authi a[href*=uid]",
            ".authi a",
            ".psta a.xi2",
            ".psta a"
        ]) ?? ""
    }

    private static func replyMetadata(for message: Element) -> String? {
        guard let container = postContainer(for: message) else {
            return nil
        }
        let floor = container.firstText(anyOf: [
            ".pi strong a em",
            ".pi strong em",
            ".mtit .y",
            "[id^=postnum] em",
            "[id^=postnum]"
        ])
        // Touch pages keep the dateline as the `.mtime` cell's own text (its
        // `span.y` child holds view/reply counters, and `.authi em` is the
        // edit link or a counter there — PC-only sources, tried after).
        let time = container.selectFirst(".authi .mtime, .mtime")
            .map { $0.ownText().htmlNormalized }?
            .nilIfBlank
            ?? container.firstText(anyOf: [
                ".authi em",
                ".pti .authi em",
                ".mtime"
            ])
        return nilIfEmpty([floor, time].compactMap(\.self).joined(separator: " · "))
    }

    private static func postContainer(for element: Element) -> Element? {
        var current: Element? = element
        while let candidate = current {
            let id = candidate.attr("id")
            if id.hasPrefix("post_") || id.hasPrefix("pid") {
                return candidate
            }
            if !candidate.select(".authi").isEmpty,
               !candidate.select("[id^=postmessage_], .message").isEmpty {
                return candidate
            }
            current = candidate.parent()
        }
        return nil
    }

    private static func postID(from element: Element) -> String? {
        let raw = element.attr("id").trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = postID(fromRawID: raw, prefix: "postmessage_") {
            return value
        }
        if let value = postID(fromRawID: raw, prefix: "pid") {
            return value
        }
        var current = element.parent()
        while let candidate = current {
            let candidateID = candidate.attr("id").trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = postID(fromRawID: candidateID, prefix: "post_") {
                return value
            }
            if let value = postID(fromRawID: candidateID, prefix: "pid") {
                return value
            }
            current = candidate.parent()
        }
        return nil
    }

    private static func isPostMessageElement(_ element: Element) -> Bool {
        let rawID = element.attr("id").trimmingCharacters(in: .whitespacesAndNewlines)
        return rawID.hasPrefix("postmessage_")
    }

    private static func postID(fromRawID rawID: String, prefix: String) -> String? {
        guard rawID.hasPrefix(prefix) else { return nil }
        let postID = String(rawID.dropFirst(prefix.count))
        guard !postID.isEmpty, postID.allSatisfy(\.isNumber) else { return nil }
        return postID
    }

    private static func authorUID(for element: Element) -> String? {
        element.selectFirst(".authi a[href*=uid]")?
            .attrURL("href")?
            .queryItemValue("uid")
    }

    private static func nextView(
        in document: Document,
        target: ReaderChapterCommentTarget,
        currentView: Int,
        isBoundaryClosed: Bool
    ) -> Int? {
        guard !isBoundaryClosed else { return nil }
        let maxView = YamiboThreadHTMLFacts.maxView(
            in: document,
            threadID: target.threadID,
            currentView: currentView
        )
        let next = currentView + 1
        return next <= maxView ? next : nil
    }

    private static func normalizeRatingReason(_ text: String) -> String {
        normalizeText(
            text
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{3000}", with: " ")
        )
    }

    private static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

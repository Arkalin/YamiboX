import Foundation

enum ChapterCommentsHTMLParser {
    static func parseInitialPage(
        html: String,
        target: ReaderChapterCommentTarget,
        isUnfiltered: Bool = false
    ) throws -> ChapterCommentsPage {
        let document = try KannaSoup.parse(html)
        var comments: [ChapterComment] = []
        comments.append(contentsOf: try postComments(in: document, target: target))
        comments.append(contentsOf: try ratingReasons(in: document, target: target))
        let replies = try samePageReplies(in: document, target: target)
        comments.append(contentsOf: replies.comments)
        let next = nextView(in: document, target: target, currentView: target.view, isBoundaryClosed: replies.isBoundaryClosed)
        let containsTarget = replyMessageNodes(in: document).contains { postID(from: $0) == target.ownerPostID }
        return ChapterCommentsPage(
            target: target,
            comments: markAuthors(comments, target: target),
            isBoundaryClosed: replies.isBoundaryClosed,
            nextView: next,
            isThreadEndConfirmed: (isUnfiltered || target.authorID == nil) && containsTarget && !replies.isBoundaryClosed && next == nil,
            pendingRatings: ratingRequests(in: document, postIDs: [target.ownerPostID] + comments.filter { $0.source == .reply }.compactMap(\.postID)),
            needsInitialRetry: (isUnfiltered || target.authorID == nil) && !containsTarget ? true : nil
        )
    }

    static func parseContinuationPage(
        html: String,
        target: ReaderChapterCommentTarget,
        view: Int
    ) throws -> ChapterCommentsPage {
        let document = try KannaSoup.parse(html)
        guard !replyMessageNodes(in: document).isEmpty else { throw ReaderChapterCommentsUnavailableError() }
        if let actualView = currentView(in: document), actualView != view {
            throw ReaderChapterCommentsUnavailableError()
        }
        let replies = try continuationReplies(in: document, target: target)
        let next = nextView(in: document, target: target, currentView: view, isBoundaryClosed: replies.isBoundaryClosed)
        return ChapterCommentsPage(
            target: target,
            comments: markAuthors(replies.comments, target: target),
            isBoundaryClosed: replies.isBoundaryClosed,
            nextView: next,
            isThreadEndConfirmed: !replyMessageNodes(in: document).isEmpty && !replies.isBoundaryClosed && next == nil,
            pendingRatings: ratingRequests(in: document, postIDs: replies.comments.filter { $0.source == .reply }.compactMap(\.postID))
        )
    }

    static func currentView(html: String, fallback: Int) throws -> Int {
        let document = try KannaSoup.parse(html)
        return currentView(in: document) ?? max(1, fallback)
    }

    private static func currentView(in document: Document) -> Int? {
        document.firstText(".pg strong").flatMap(Int.init)
            ?? document.selectFirst("#dumppage option[selected], select[name=page] option[selected]")?.attrText("value").flatMap(Int.init)
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
        try YamiboHTMLPageInspector.ensureReadable(html)
        let payload = HTMLTextExtractor.discuzAjaxPayload(from: html) ?? html
        let document = try KannaSoup.parse(payload)
        let rows = document.select(".post_box li.flex-box").array()
        var comments: [ChapterComment] = []
        var hasRatingStructure = false
        var pending: (author: String, uid: String?, metadata: String?, avatarURL: URL?)?

        for row in rows {
            let values = row.select("span.z, span.y").array().map { normalizeText($0.text()) }
            if values.count >= 3, values[0].contains("积分") {
                hasRatingStructure = true
                pending = (
                    author: values[1],
                    uid: row.select("a[href]").array().compactMap(linkUID).first,
                    metadata: nilIfEmpty([values[0], values[2]].joined(separator: " · ")),
                    avatarURL: avatarURL(in: row)
                )
                continue
            }

            let body = try ChapterCommentBodyParser.parse(row.select("span.z, span.y").first())
            guard let current = pending,
                  !body.isEmpty else {
                pending = nil
                continue
            }
            comments.append(
                ChapterComment(
                    id: "\(target.ownerPostID):rating-full:\(comments.count)",
                    source: .ratingReason,
                    authorName: normalizeText(current.author),
                    metadata: current.metadata,
                    body: normalizeRatingReason(body.text),
                    postID: target.ownerPostID,
                    bodyBlocks: body.bodyBlocks,
                    authorUID: current.uid,
                    authorAvatarURL: current.avatarURL,
                    contentBlocks: body.contentBlocks
                )
            )
            pending = nil
        }

        // Ratings may all omit reasons. Validate the page, not the number of comments.
        guard hasRatingStructure else { throw ReaderChapterCommentsUnavailableError() }
        return comments
    }

    private static func postComments(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> [ChapterComment] {
        let rows = document.select("#comment_\(target.ownerPostID) .pstl")
        var comments: [ChapterComment] = try rows.array().enumerated().compactMap { offset, row in
            let author = row.firstText(anyOf: [".psta a.xi2", ".psta a.xw1"])
                ?? row.selectAll(".psta a").compactMap { $0.normalizedText().nilIfBlank }.first ?? ""
            guard let bodyElement = row.select(".psti").first() else { return nil }
            let metadata = bodyElement.select(".xg1").first()?.text()
            bodyElement.select(".xg1").remove()
            let body = try ChapterCommentBodyParser.parse(bodyElement)
            guard !body.isEmpty else { return nil }
            return ChapterComment(
                id: "\(target.ownerPostID):comment:\(offset)",
                source: .postComment,
                authorName: normalizeText(author),
                metadata: nilIfEmpty(normalizeText(metadata ?? "")),
                body: body.text,
                postID: target.ownerPostID,
                bodyBlocks: body.bodyBlocks,
                authorUID: row.selectAll(".psta a[href]").compactMap(linkUID).first,
                authorAvatarURL: avatarURL(in: row.selectFirst(".psta")),
                contentBlocks: body.contentBlocks
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
            let authorLink = cells.first()?.select("a").last()
            let author = authorLink?.text() ?? ""
            let body = try ChapterCommentBodyParser.parse(row.select("td.xg1").first())
            let reason = normalizeRatingReason(body.text)
            guard !body.isEmpty else {
                return nil
            }
            return ChapterComment(
                id: "\(target.ownerPostID):rating:\(offset)",
                source: .ratingReason,
                authorName: normalizeText(author),
                body: reason,
                postID: target.ownerPostID,
                bodyBlocks: body.bodyBlocks,
                authorUID: authorLink.flatMap(linkUID),
                authorAvatarURL: avatarURL(in: cells.first()),
                contentBlocks: body.contentBlocks
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
            let authorLinks = row.selectAll("a").filter { link in
                !link.parents().contains { $0.hasClass("mtxt") || $0.hasClass("mtime") }
            }
            let author = authorLinks.compactMap { $0.normalizedText().nilIfBlank }.first ?? ""
            let metadata = row.select(".mtime").first()?.text()
            let body = try ChapterCommentBodyParser.parse(row.select(".mtxt").first())
            guard !body.isEmpty else { return nil }
            return ChapterComment(
                id: "\(target.ownerPostID):comment-mobile:\(offset)",
                source: .postComment,
                authorName: normalizeText(author),
                metadata: nilIfEmpty(normalizeText(metadata ?? "")),
                body: body.text,
                postID: target.ownerPostID,
                bodyBlocks: body.bodyBlocks,
                authorUID: authorLinks.compactMap(linkUID).first,
                authorAvatarURL: avatarURL(
                    in: row,
                    imageSelector: ".avatar img[src], .mimg img[src], li:first-child img[src]"
                ),
                contentBlocks: body.contentBlocks
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
            let authorLink = cells[0].select("a").last()
            let author = authorLink?.text() ?? ""
            let body = try ChapterCommentBodyParser.parse(cells[2])
            let reason = normalizeRatingReason(body.text)
            guard reason != "理由",
                  !body.isEmpty else {
                return nil
            }
            return ChapterComment(
                id: "\(target.ownerPostID):rating-mobile:\(offset)",
                source: .ratingReason,
                authorName: normalizeText(author),
                body: reason,
                postID: target.ownerPostID,
                bodyBlocks: body.bodyBlocks,
                authorUID: authorLink.flatMap(linkUID),
                authorAvatarURL: avatarURL(in: cells[0]),
                contentBlocks: body.contentBlocks
            )
        }
    }

    private static func samePageReplies(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> (comments: [ChapterComment], isBoundaryClosed: Bool) {
        try replies(in: document, target: target, isContinuation: false)
    }

    private static func continuationReplies(
        in document: Document,
        target: ReaderChapterCommentTarget
    ) throws -> (comments: [ChapterComment], isBoundaryClosed: Bool) {
        try replies(in: document, target: target, isContinuation: true)
    }

    private static func replies(
        in document: Document,
        target: ReaderChapterCommentTarget,
        isContinuation: Bool
    ) throws -> (comments: [ChapterComment], isBoundaryClosed: Bool) {
        let messageNodes = replyMessageNodes(in: document)
        var foundTarget = isContinuation
        var comments: [ChapterComment] = []

        for message in messageNodes {
            guard let postID = postID(from: message) else { continue }
            if postID == target.ownerPostID {
                foundTarget = true
                continue
            }
            guard foundTarget else { continue }
            let reference = ForumPostReplyReferenceParser.parse(in: message, threadID: target.threadID)
            let isAuthor = isOwnerPost(message, target: target)
            if isAuthor, reference == nil {
                return (comments, true)
            }
            let body = try ChapterCommentBodyParser.parse(message, attachmentsFrom: postContainer(for: message))
            let quotes = try ChapterCommentBodyParser.quotes(in: message)
            var postTarget = target
            postTarget.ownerPostID = postID
            let attached = try postComments(in: document, target: postTarget) + ratingReasons(in: document, target: postTarget)
            guard !body.isEmpty || quotes != nil || !attached.isEmpty else { continue }
            let metadata = replyMetadata(for: message)
            comments.append(
                ChapterComment(
                    id: "\(target.ownerPostID):reply:\(postID)",
                    source: .reply,
                    authorName: authorName(for: message),
                    metadata: metadata,
                    body: body.text,
                    postID: postID,
                    bodyBlocks: body.bodyBlocks,
                    authorUID: postContainer(for: message).flatMap { authorUID(for: $0) },
                    authorAvatarURL: replyAvatarURL(for: message),
                    contentBlocks: body.contentBlocks,
                    replyReference: reference,
                    postedAt: metadata.flatMap(ForumPostReplyReferenceParser.timestamp),
                    isThreadAuthor: isAuthor,
                    quoteBlocks: quotes
                )
            )
            comments.append(contentsOf: attached)
        }

        return (comments, false)
    }

    private static func markAuthors(_ comments: [ChapterComment], target: ReaderChapterCommentTarget) -> [ChapterComment] {
        comments.map { comment in
            var result = comment
            if let uid = comment.authorUID, let authorID = target.authorID { result.isThreadAuthor = uid == authorID }
            return result
        }
    }

    private static func ratingRequests(in document: Document, postIDs: [String]) -> [ChapterCommentRatingRequest] {
        var seen = Set<String>()
        return postIDs.compactMap { pid in
            guard seen.insert(pid).inserted,
                  let url = document.firstURL("[id=ratelog_\(pid)] a[href*=action=viewratings]") else { return nil }
            return ChapterCommentRatingRequest(postID: pid, url: url)
        }
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

    private static func avatarURL(
        in element: Element?,
        imageSelector: String = "img[src]"
    ) -> URL? {
        guard let element else { return nil }
        for image in element.selectAll(imageSelector) {
            let isCommentContent = image.parents().contains { $0.hasClass("mtxt") || $0.hasClass("mtime") }
            if !isCommentContent, let url = image.attrURL("src") {
                return url
            }
        }
        guard let uid = element.selectAll("a[href]").filter({ link in
            !link.parents().contains { $0.hasClass("mtxt") || $0.hasClass("mtime") }
        }).compactMap({
            ForumUserIDParser.userID(fromHref: $0.attr("href"))
        }).first, !uid.isEmpty, uid.allSatisfy(\.isNumber), uid != "0" else { return nil }
        var components = URLComponents(url: YamiboDomain.baseURL.appendingPathComponent("uc_server/avatar.php"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "uid", value: uid), URLQueryItem(name: "size", value: "small")]
        return components?.url
    }

    private static func replyAvatarURL(for message: Element) -> URL? {
        guard let container = postContainer(for: message) else { return nil }
        // Never use images from the reply body or another user's inline comments.
        for image in container.selectAll(".avatar img[src], .pls .avt img[src]") {
            let isCommentContent = image.parents().contains {
                $0.hasClass("message") || $0.id().hasPrefix("postmessage_")
                    || $0.id().hasPrefix("comment_") || $0.id().hasPrefix("commentdetail_")
            }
            if !isCommentContent, let url = image.attrURL("src") {
                return url
            }
        }
        return avatarURL(in: container.selectFirst(".authi"), imageSelector: "a[href*=uid] img[src]")
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
        element.select(".authi a[href*=uid], .psta a[href*=uid]").array().compactMap(linkUID).first
    }

    private static func linkUID(_ element: Element) -> String? {
        guard let url = element.attrURL("href") else { return nil }
        if let uid = url.queryItemValue("uid"), !uid.isEmpty { return uid }
        if case let .userSpace(uid, _) = ForumRouteResolver.resolve(url: url) { return uid }
        return nil
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

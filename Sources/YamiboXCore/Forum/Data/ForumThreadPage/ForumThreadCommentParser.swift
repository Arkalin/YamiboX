import Foundation

/// Parses the inline comment ("点评") list attached to a post.
enum ForumThreadCommentParser {
    static func comments(in container: Element, postID: String) throws -> [ForumThreadPostComment] {
        let roots = try (
            container.selectAll("#comment_\(postID)") + container.selectAll(".cm, [id^=comment_]")
        ).deduplicatedByDOMIdentity()
        var comments: [ForumThreadPostComment] = []
        var seen: Set<String> = []

        for root in roots {
            let rows = root.selectAll(".pstl, li, .comment")
            let commentRows = rows.isEmpty ? [root] : rows
            for (index, row) in commentRows.enumerated() {
                guard let comment = try comment(in: row, root: root, postID: postID, index: index),
                      seen.insert(comment.id).inserted else {
                    continue
                }
                comments.append(comment)
            }
        }
        return comments
    }

    private static func comment(
        in row: Element,
        root: Element,
        postID: String,
        index: Int
    ) throws -> ForumThreadPostComment? {
        let messageElement = row.selectFirst(".psti, .comment_content, .message") ?? row
        let metadataText = messageElement.selectAll(".xg1, .time, .date")
            .compactMap { $0.normalizedText().nilIfBlank }
            .joined(separator: " ")
            .nilIfBlank
        let messageDocument = try KannaSoup.parseBodyFragment(try messageElement.html(), baseURL: YamiboDomain.baseURL.absoluteString)
        let messageBody = messageDocument.body() ?? messageDocument
        try messageBody.select(".xg1, .time, .date").remove()
        let message = messageBody.normalizedText()
        guard !message.isEmpty else { return nil }

        let authorLink = row.selectFirst(".psta a[href*='uid='], .psta a[href*='space-uid-'], .psta a, a[href*='uid='], a[href*='space-uid-']")
        let authorName = (authorLink?.normalizedText() ?? "")
            .nilIfBlank
            ?? L10n.string("reader.comment_anonymous")
        let uid = authorLink.flatMap { ForumUserIDParser.userID(fromHref: (try? $0.attr("href")) ?? "") }
        let id = root.id().nilIfBlank.map { "\($0)-\(index)" }
            ?? "\(postID)-comment-\(index)"
        return ForumThreadPostComment(
            id: id,
            author: BlogReaderUser(uid: uid, name: authorName, avatarURL: nil),
            postedAtText: metadataText,
            message: message
        )
    }
}

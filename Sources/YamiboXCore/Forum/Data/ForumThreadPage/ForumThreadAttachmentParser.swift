import Foundation

/// Parses attachment listings of a post: the in-body `ul.post_attlist` block and
/// the attachment entries rendered in the post footer.
enum ForumThreadAttachmentParser {
    /// Attachment described by an in-body `ul.post_attlist` element, or nil.
    static func attachmentListBlock(from element: Element) -> ForumThreadAttachmentBlock? {
        guard let link = element.select("a[href]").first(),
              let url = HTMLTextExtractor.absoluteURL(from: link.attr("href")) else {
            return nil
        }
        let fileName = link.select(".link").first()?.text().nilIfBlank
            ?? link.select(".tit").first()?.ownText().nilIfBlank
            ?? link.text().split(separator: "\n").map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .nilIfBlank
        guard let fileName else { return nil }

        let metadata = link.select("p").array()
            .compactMap { $0.text().nilIfBlank }
        return ForumThreadAttachmentBlock(
            url: url,
            iconURL: link.select("img[src]").first().flatMap { HTMLTextExtractor.absoluteURL(from: $0.attr("src")) },
            fileName: fileName,
            uploadInfo: metadata.first,
            statInfo: metadata.dropFirst().first
        )
    }

    /// Attachments listed in the post footer, excluding ones nested inside the message body.
    static func footerAttachments(in container: Element, body: Element) -> [ForumThreadAttachmentBlock] {
        let bodyElementID = body.id()
        let candidates = container.selectAll(".pattl, .attach, .t_attach, [id^=attach_]")
            .filter { element in
                guard !bodyElementID.isEmpty else { return true }
                return element.parents().contains { $0.id() == bodyElementID } != true
            }
        return candidates.compactMap(attachment(fromFooterElement:))
    }

    private static func attachment(fromFooterElement element: Element) -> ForumThreadAttachmentBlock? {
        guard let link = element.selectFirst("a[href]"),
              let url = link.attrURL("href") else {
            return nil
        }
        let text = element.normalizedText()
        let fileName = link.normalizedText().nilIfBlank
            ?? text.components(separatedBy: " ").first?.nilIfBlank
        guard let fileName else { return nil }
        let statInfo = HTMLTextExtractor.firstMatch(
            pattern: #"((?:\d+(?:\.\d+)?\s*(?:KB|MB|GB|字节|位元組|bytes?))|(?:\d+\s*(?:次下载|次下載|downloads?)))"#,
            in: text
        )?
            .dropFirst()
            .first?
            .nilIfBlank
        return ForumThreadAttachmentBlock(
            url: url,
            iconURL: element.firstURL("img[src]", attribute: "src"),
            fileName: fileName,
            uploadInfo: nil,
            statInfo: statInfo
        )
    }
}

import Foundation

struct ChapterCommentParsedBody {
    var text = ""
    var bodyBlocks: [ForumThreadTextBlock]?
    var contentBlocks: [ForumThreadContentBlock]?

    var hasMedia: Bool { bodyBlocks != nil || contentBlocks != nil }
    var isEmpty: Bool { text.isEmpty && !hasMedia }
}

enum ChapterCommentBodyParser {
    private static let imageReferences = YamiboImageReferenceExtractor(
        attributes: ["file", "zoomfile", "zsrc", "src"], rejectedSubstrings: ["none.gif"]
    )

    static func parse(
        _ element: Element?,
        attachmentsFrom container: Element? = nil
    ) throws -> ChapterCommentParsedBody {
        guard let element, !([element] + element.parents()).contains(where: isHidden) else { return ChapterCommentParsedBody() }
        let fragment = try KannaSoup.parseBodyFragment(element.html())
        guard let body = fragment.body() else { return ChapterCommentParsedBody() }
        prepare(body)

        let content: Element
        if let container {
            let attachmentCopy = try KannaSoup.parseBodyFragment(container.html())
            prepare(attachmentCopy)
            attachmentCopy.select("[id^=comment_], [id^=commentdetail_], [id^=ratelog_], .authi").remove()
            let attachments = ForumThreadPostsParser.attachmentImagesHTML(in: attachmentCopy, body: body)
            let combined = try KannaSoup.parseBodyFragment(([body.html()] + attachments).joined(separator: "\n"))
            content = combined.body() ?? combined
        } else {
            content = body
        }

        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(in: content).flatMap(displayBlocks).enumerated().map { index, block in
            ForumThreadContentBlock(id: "content-\(index)", kind: block.kind)
        }
        let textBlocks = blocks.compactMap { block -> ForumThreadTextBlock? in
            guard case let .text(text) = block.kind else { return nil }
            return text
        }
        let hasPhotos = blocks.contains { if case .image = $0.kind { true } else { false } }
        return ChapterCommentParsedBody(
            text: content.normalizedText(),
            bodyBlocks: textBlocks.contains { !$0.inlineImages.isEmpty } ? textBlocks : nil,
            contentBlocks: hasPhotos ? blocks : nil
        )
    }

    private static func prepare(_ body: Element) {
        body.select(".quote, blockquote, .pstatus, .lastedit, .lastedited, .editinfo, .edited, .avatar, .avt, .jammer, [hidden]").remove()
        for element in body.selectAll("[style]") where isHidden(element) { element.remove() }
        // Normalize only this detached comment copy. The shared forum parser keeps its defaults.
        for image in body.selectAll("img") {
            guard let url = imageReferences.url(from: image),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                image.remove()
                continue
            }
            for attribute in ["file", "src", "zsrc"] { image.setAttribute(attribute, value: url.absoluteString) }
        }
    }

    private static func isHidden(_ element: Element) -> Bool {
        let style = element.attr("style").lowercased().filter { !$0.isWhitespace }
        return element.hasAttribute("hidden") || element.hasClass("jammer")
            || style.contains("display:none") || style.contains("visibility:hidden")
    }

    private static func displayBlocks(_ block: ForumThreadContentBlock) -> [ForumThreadContentBlock] {
        switch block.kind {
        case let .text(text):
            return [ForumThreadContentBlock(id: block.id, kind: .text(ForumThreadTextBlock(text: text.text, inlineImages: text.inlineImages)))]
        case var .image(image):
            image.linkURL = nil
            return [ForumThreadContentBlock(id: block.id, kind: .image(image))]
        case let .collapse(_, blocks), let .locked(_, blocks):
            return blocks.flatMap(displayBlocks)
        case let .table(rows):
            return rows.flatMap { $0.flatMap { $0.blocks.flatMap(displayBlocks) } }
        case let .code(text):
            return [ForumThreadContentBlock(id: block.id, kind: .text(ForumThreadTextBlock(text: text)))]
        case .quote, .attachment, .horizontalRule:
            return []
        }
    }
}

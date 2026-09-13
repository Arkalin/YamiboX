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

    static func quotes(in element: Element) throws -> [ForumThreadContentBlock]? {
        guard !([element] + element.parents()).contains(where: isHidden) else { return nil }
        let quotes = element.selectAll(".quote, blockquote").filter { candidate in
            !([candidate] + candidate.parents()).contains(where: isHidden)
                && !candidate.parents().contains { $0.hasClass("quote") || $0.tagName() == "blockquote" }
        }
        let blocks = try quotes.enumerated().compactMap { index, quote -> ForumThreadContentBlock? in
            let fragment = try KannaSoup.parseBodyFragment(quote.html())
            // Drop only the Discuz wrapper; nested quoted conversations stay hidden.
            if let wrapper = fragment.selectFirst("body > blockquote") {
                let inner = try KannaSoup.parseBodyFragment(wrapper.html())
                return try quoteBlock(inner.body(), index: index)
            }
            return try quoteBlock(fragment.body(), index: index)
        }
        return blocks.isEmpty ? nil : blocks
    }

    private static func quoteBlock(_ element: Element?, index: Int) throws -> ForumThreadContentBlock? {
        let parsed = try parse(element)
        guard !parsed.isEmpty else { return nil }
        let content = parsed.contentBlocks ?? parsed.bodyBlocks?.enumerated().map {
            ForumThreadContentBlock(id: "quote-\(index)-text-\($0.offset)", kind: .text($0.element))
        } ?? [ForumThreadContentBlock(id: "quote-\(index)-text", kind: .text(ForumThreadTextBlock(text: parsed.text)))]
        return ForumThreadContentBlock(id: "quote-\(index)", kind: .quote(content.map {
            ForumThreadContentBlock(id: "quote-\(index)-\($0.id)", kind: $0.kind)
        }))
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

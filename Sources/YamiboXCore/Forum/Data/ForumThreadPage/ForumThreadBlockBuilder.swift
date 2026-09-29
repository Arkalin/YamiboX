import Foundation

/// Stateful DOM walker that flattens a sanitized post-body fragment into content blocks.
///
/// Inline markup accumulates into a pending text run (with links, styles, rubies and smileys);
/// block-level markup commits the pending run and emits structural blocks
/// (quote, image, code, table, collapse, locked, attachment, ...). One instance
/// parses one fragment; nested fragments recurse through `ForumThreadHTMLBlockParser`.
final class ForumThreadBlockBuilder {
    private struct PendingTextLink {
        var start: Int
        var length: Int
        var url: URL
    }

    private struct PendingTextStyleRun {
        var start: Int
        var length: Int
        var style: ForumThreadTextStyle
    }

    private struct PendingRubyText {
        var start: Int
        var length: Int
        var baseText: String
        var rubyText: String
    }

    private var blocks: [ForumThreadContentBlock] = []
    private var text = ""
    private var links: [PendingTextLink] = []
    private var styleRuns: [PendingTextStyleRun] = []
    private var rubies: [PendingRubyText] = []
    private var inlineImages: [ForumThreadInlineImage] = []
    private var currentLinkURL: URL?
    private var currentStyle = ForumThreadTextStyle()
    private var currentAlignment = ForumThreadTextAlignment.start
    private var currentParagraphStyle: ForumThreadParagraphStyle?
    private struct ListContext {
        var type: String
        var nextNumber: Int
    }
    private var lists: [ListContext] = []
    private var blockCounter = 0

    init(style: ForumThreadTextStyle = ForumThreadTextStyle(),
         alignment: ForumThreadTextAlignment = .start,
         paragraphStyle: ForumThreadParagraphStyle? = nil, linkURL: URL? = nil) {
        currentStyle = style
        currentAlignment = alignment
        currentParagraphStyle = paragraphStyle
        currentLinkURL = linkURL
    }

    func parse(nodes: [Node]) throws -> [ForumThreadContentBlock] {
        for node in nodes {
            try parse(node: node)
        }
        commitText()
        return blocks
    }

    private func parse(node: Node) throws {
        if let textNode = node as? TextNode {
            appendTextNodeText(textNode.getWholeText())
            return
        }

        guard let element = node as? Element else {
            for child in node.getChildNodes() {
                try parse(node: child)
            }
            return
        }

        let previousStyle = currentStyle
        currentStyle = currentStyle.merged(with: ForumTextStyleRules.style(fromStyleAttribute: element.attr("style")))
        defer { currentStyle = previousStyle }
        let tagName = element.tagName().lowercased()
        switch tagName {
        case "br":
            appendLineBreak(explicit: true)
        case "hr":
            commitText()
            appendBlock(.horizontalRule, seed: "hr")
        case "img":
            appendImage(from: element)
        case "blockquote":
            commitText()
            appendBlock(.indent(try nestedBlocks(html: element.html())), seed: "indent")
        case "div":
            try parseDiv(element)
        case "pre":
            commitText()
            let code = Self.verbatimText(in: element)
            appendBlock(.code(code), seed: "code-\(code)")
        case "table":
            try parseTable(element)
        case "ul", "ol":
            try parseUnorderedList(element)
        case "a":
            try parseLink(element)
        case "b", "strong":
            try withTextStyle(ForumThreadTextStyle(isBold: true)) {
                try parseChildren(of: element)
            }
        case "i", "em":
            try withTextStyle(ForumThreadTextStyle(isItalic: true)) {
                try parseChildren(of: element)
            }
        case "u":
            try withTextStyle(ForumThreadTextStyle(isUnderline: true)) {
                try parseChildren(of: element)
            }
        case "s", "strike":
            try withTextStyle(ForumThreadTextStyle(isStrikethrough: true)) {
                try parseChildren(of: element)
            }
        case "sup", "sub":
            try withTextStyle(ForumThreadTextStyle(baseline: tagName == "sup" ? 1 : -1)) {
                try parseChildren(of: element)
            }
        case "ruby":
            try parseRuby(element)
        case "rt", "rp":
            return
        case "font":
            try withTextStyle(ForumThreadTextStyleParser.style(fromFontElement: element)) {
                try parseChildren(of: element)
            }
        case "span":
            try withTextStyle(ForumTextStyleRules.style(fromStyleAttribute: element.attr("style"))) {
                try parseChildren(of: element)
            }
        case "p":
            try parseBlockContainer(element)
        case "tbody", "tr", "td", "th":
            appendLineBreak(maxConsecutive: 1)
            try parseChildren(of: element)
            appendLineBreak(maxConsecutive: 1)
        case "li":
            appendLineBreak(maxConsecutive: 1)
            appendText(listMarker() + " ")
            try parseChildren(of: element)
            appendLineBreak(maxConsecutive: 1)
        case "script", "style":
            return
        default:
            try parseChildren(of: element)
        }
    }

    private func parseDiv(_ element: Element) throws {
        let classes = element.className().lowercased()
        if classes.contains("showcollapse_box") {
            commitText()
            // Only consume this box's controls; nested boxes keep their own titles.
            let controls = element.select(".showcollapse_title, .showcollapse_gather").array().filter { control in
                control.parents().first(where: { $0.hasClass("showcollapse_box") })?
                    .isSameDOMNode(as: element) == true
            }
            let titleNode = controls.first(where: { $0.hasClass("showcollapse_title") })
            let title = titleNode?.text().nilIfBlank
            // The trailing web control is rendered as a native button by the UI.
            controls.forEach { $0.remove() }
            let contentBlocks = try nestedBlocks(html: element.html())
            appendBlock(
                .collapse(title: title, contentBlocks: contentBlocks),
                seed: "collapse-\(title ?? "")"
            )
            return
        }

        if classes.contains("locked-content") {
            commitText()
            let costText = element.select(".locked-tip").text()
            let cost = HTMLTextExtractor.firstMatch(pattern: #"(\d+)"#, in: costText)?
                .dropFirst()
                .first
                .flatMap(Int.init)
            element.select(".locked-tip").remove()
            let contentBlocks = try nestedBlocks(html: element.html())
            appendBlock(
                .locked(cost: cost, contentBlocks: contentBlocks),
                seed: "locked-\(costText)"
            )
            return
        }

        if classes.contains("quote") || classes.contains("blockquote") {
            try appendQuote(from: element)
            return
        }

        if classes.contains("blockcode") {
            commitText()
            // Discuz wraps each original line in li and appends a copy control.
            // Ignore serializer whitespace between li, not whitespace inside a line.
            let source = element.selectFirst("ol, pre") ?? element
            let code: String
            if source.tagName().lowercased() == "ol" {
                code = source.children().array().filter { $0.tagName().lowercased() == "li" }
                    .map { $0.getChildNodes().map(Self.verbatimText(in:)).joined() }
                    .joined(separator: "\n")
            } else {
                code = Self.verbatimText(in: source)
            }
            appendBlock(.code(code), seed: "code-\(code)")
            return
        }

        try parseBlockContainer(element)
    }

    private func parseBlockContainer(_ element: Element) throws {
        let alignment = textAlignment(from: element) ?? currentAlignment
        let previousParagraphStyle = currentParagraphStyle
        let paragraphStyle = ForumThreadTextStyleParser.paragraphStyle(from: element, inheriting: previousParagraphStyle)
        if paragraphStyle != previousParagraphStyle { commitText() }
        currentParagraphStyle = paragraphStyle
        defer {
            if paragraphStyle != previousParagraphStyle { commitText() }
            currentParagraphStyle = previousParagraphStyle
        }
        try withTextAlignment(alignment) {
            appendLineBreak(maxConsecutive: 1)
            try parseChildren(of: element)
            appendLineBreak(maxConsecutive: 1)
        }
    }

    private func parseTable(_ element: Element) throws {
        let rows = element.select("tr").array().filter { row in
            row.parents().first { $0.tagName().lowercased() == "table" }?.isSameDOMNode(as: element) == true
        }
        guard !rows.isEmpty else {
            try parseChildren(of: element)
            return
        }

        commitText()
        let tableRows = try rows.map { row in
            try row.children().array().filter { ["td", "th"].contains($0.tagName().lowercased()) }.map { cell in
                let tagName = cell.tagName().lowercased()
                let rowStyle = currentStyle.merged(with: ForumTextStyleRules.style(fromStyleAttribute: row.attr("style")))
                let cellStyle = rowStyle
                    .merged(with: ForumThreadTextStyle(isBold: tagName == "th"))
                    .merged(with: ForumTextStyleRules.style(fromStyleAttribute: cell.attr("style")))
                let background = cellStyle.backgroundHex
                    ?? ForumTextStyleRules.normalizedColorHex(cell.attr("bgcolor"))
                    ?? ForumTextStyleRules.normalizedColorHex(row.attr("bgcolor"))
                    ?? ForumTextStyleRules.normalizedColorHex(element.attr("bgcolor"))
                return ForumThreadTableCell(
                    isHeader: tagName == "th",
                    blocks: try nestedBlocks(
                        html: cell.html(), style: cellStyle,
                        alignment: textAlignment(from: cell) ?? textAlignment(from: row) ?? textAlignment(from: element),
                        paragraphStyle: ForumThreadTextStyleParser.paragraphStyle(from: cell, inheriting: currentParagraphStyle)
                    ),
                    columnSpan: min(max(Int(cell.attr("colspan")) ?? 1, 1), 100),
                    rowSpan: min(max(Int(cell.attr("rowspan")) ?? 1, 1), min(100, rows.count)),
                    backgroundHex: background
                )
            }
        }
        appendBlock(.table(rows: tableRows), seed: "table-\(tableRows.count)")
    }

    private func parseUnorderedList(_ element: Element) throws {
        let classes = element.className().lowercased()
        if classes.contains("post_attlist"),
           let attachment = ForumThreadAttachmentParser.attachmentListBlock(from: element) {
            commitText()
            appendBlock(.attachment(attachment), seed: "attachment-\(attachment.fileName)")
            return
        }

        let isNested = !lists.isEmpty
        commitText()
        let blockStart = blocks.count
        let type = element.attr("type").nilIfBlank
            ?? (classes.contains("litype_1") ? "1" : classes.contains("litype_2") ? "a" : classes.contains("litype_3") ? "A" : element.tagName() == "ol" ? "1" : "bullet")
        lists.append(ListContext(type: type, nextNumber: max(Int(element.attr("start")) ?? 1, 1)))
        try parseChildren(of: element)
        commitText()
        lists.removeLast()
        if isNested {
            let children = Array(blocks[blockStart...])
            blocks.removeSubrange(blockStart...)
            appendBlock(.indent(children), seed: "nested-list")
        }
    }

    private func parseLink(_ element: Element) throws {
        guard let url = HTMLTextExtractor.absoluteURL(from: element.attr("href")) else {
            try parseChildren(of: element)
            return
        }

        let previousLinkURL = currentLinkURL
        currentLinkURL = url
        defer { currentLinkURL = previousLinkURL }
        try parseChildren(of: element)
    }

    private func parseRuby(_ element: Element) throws {
        let rubyText = element.children()
            .array()
            .filter { $0.tagName().lowercased() == "rt" }
            .map { $0.text() }
            .joined()
            .nilIfBlank
        guard let rubyText else {
            try parseChildren(of: element)
            return
        }

        let start = text.count
        try parseChildren(of: element)
        guard text.count > start else { return }
        let baseText = String(text.dropFirst(start))
        rubies.append(
            PendingRubyText(
                start: start,
                length: baseText.count,
                baseText: baseText,
                rubyText: rubyText
            )
        )
    }

    private func appendQuote(from element: Element) throws {
        commitText()
        appendBlock(
            .quote(try nestedBlocks(html: quoteContentHTML(from: element))),
            seed: "quote-\(element.text().prefix(32))"
        )
    }

    private func quoteContentHTML(from element: Element) -> String {
        guard element.tagName().lowercased() != "blockquote" else {
            return element.html()
        }

        let directChildren = element.children().array()
        let blockquoteChildren = directChildren.filter { $0.tagName().lowercased() == "blockquote" }
        let hasOnlyWhitespaceOutsideBlockquote = element.getChildNodes().allSatisfy { node in
            if let childElement = node as? Element {
                return childElement.tagName().lowercased() == "blockquote"
                    || childElement.tagName().lowercased() == "br"
            }
            if let textNode = node as? TextNode {
                return textNode.text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }

        if blockquoteChildren.count == 1, hasOnlyWhitespaceOutsideBlockquote {
            return blockquoteChildren[0].html()
        }

        return element.html()
    }

    private func appendImage(from element: Element) {
        guard let url = YamiboImageReferenceExtractor.forumContent.url(from: element) else {
            return
        }

        let image = ForumThreadImageBlock(
            url: url,
            altText: element.attr("alt"),
            linkURL: currentLinkURL,
            isEmoticon: YamiboImageReferenceExtractor.isEmoticonURL(url),
            width: Self.imageDimension(element.attr("width")),
            height: Self.imageDimension(element.attr("height"))
        )
        if image.isEmoticon {
            inlineImages.append(ForumThreadInlineImage(start: text.count, image: image))
            appendText("\u{FFFC}")
        } else {
            commitText()
            appendBlock(.image(image), seed: "image-\(url.absoluteString)")
        }
    }

    private func parseChildren(of element: Element) throws {
        for child in element.getChildNodes() {
            try parse(node: child)
        }
    }

    private func withTextStyle(_ style: ForumThreadTextStyle, parse: () throws -> Void) throws {
        let previousStyle = currentStyle
        currentStyle = previousStyle.merged(with: style)
        try parse()
        currentStyle = previousStyle
    }

    private func appendTextNodeText(_ value: String) {
        for character in value {
            switch character {
            case "\u{00A0}":
                appendText("\u{3000}")
            // Discuz can emit <br> followed by CRLF. Swift treats CRLF as
            // one Character; fold it as HTML whitespace, not a second break.
            case " ", "\n", "\r", "\r\n", "\t", "\u{000C}":
                appendCollapsibleSpace()
            default:
                appendText(String(character))
            }
        }
    }

    private func appendText(_ value: String) {
        // Kanna already decoded text nodes. Decoding again corrupts literal &lt; examples.
        let decoded = value
        guard !decoded.isEmpty else { return }
        let start = text.count
        text += decoded
        appendCurrentStyleRun(start: start, length: decoded.count)
        if let url = currentLinkURL {
            if let last = links.last, last.url == url, last.start + last.length == start {
                links[links.count - 1].length += decoded.count
            } else {
                links.append(PendingTextLink(start: start, length: decoded.count, url: url))
            }
        }
    }

    private func appendLineBreak(maxConsecutive: Int = 2, explicit: Bool = false) {
        guard !text.isEmpty || explicit else { return }
        let trailing = text.reversed().prefix(while: { $0 == "\n" }).count
        if trailing < maxConsecutive {
            appendText("\n")
        }
    }

    private func appendCollapsibleSpace() {
        guard let last = text.last else { return }
        if last != " ", last != "\n", last != "\u{3000}" {
            appendText(" ")
        }
    }

    private func commitText() {
        let normalizedResult = ForumThreadTextNormalizer.normalize(text)
        let normalized = normalizedResult.text
        guard !normalized.isEmpty else {
            text = ""
            links = []
            styleRuns = []
            rubies = []
            inlineImages = []
            return
        }

        let blockLinks = links.compactMap { link -> ForumThreadTextLink? in
            guard let range = normalizedResult.range(start: link.start, length: link.length) else { return nil }
            return ForumThreadTextLink(start: range.start, length: range.length, url: link.url)
        }
        let blockStyleRuns = styleRuns.compactMap { run -> ForumThreadTextStyleRun? in
            guard let range = normalizedResult.range(start: run.start, length: run.length) else { return nil }
            return ForumThreadTextStyleRun(start: range.start, length: range.length, style: run.style)
        }
        let blockRubies = rubies.compactMap { ruby -> ForumThreadRubyText? in
            guard let range = normalizedResult.range(start: ruby.start, length: ruby.length) else { return nil }
            return ForumThreadRubyText(
                start: range.start,
                length: range.length,
                baseText: ruby.baseText,
                rubyText: ruby.rubyText
            )
        }
        appendBlock(
            .text(
                ForumThreadTextBlock(
                    text: normalized,
                    alignment: currentAlignment,
                    links: blockLinks,
                    styleRuns: blockStyleRuns,
                    rubies: blockRubies,
                    inlineImages: inlineImages.compactMap { inline in
                        guard let range = normalizedResult.range(start: inline.start, length: 1) else { return nil }
                        return ForumThreadInlineImage(start: range.start, image: inline.image)
                    },
                    paragraphStyle: currentParagraphStyle
                )
            ),
            seed: "text-\(normalized.prefix(64))"
        )
        text = ""
        links = []
        styleRuns = []
        rubies = []
        inlineImages = []
    }

    private func withTextAlignment(
        _ alignment: ForumThreadTextAlignment,
        parse: () throws -> Void
    ) throws {
        let previousAlignment = currentAlignment
        if alignment != previousAlignment {
            commitText()
            currentAlignment = alignment
        }
        try parse()
        if alignment != previousAlignment {
            commitText()
            currentAlignment = previousAlignment
        }
    }

    private func textAlignment(from element: Element) -> ForumThreadTextAlignment? {
        let css = ForumTextStyleRules.styleDeclarations(from: element.attr("style"))
        switch (css["text-align"] ?? element.attr("align")).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "center":
            return .center
        case "right":
            return .right
        case "left":
            return .left
        default:
            return nil
        }
    }

    private func nestedBlocks(html: String, style: ForumThreadTextStyle? = nil,
                              alignment: ForumThreadTextAlignment? = nil,
                              paragraphStyle: ForumThreadParagraphStyle? = nil) throws -> [ForumThreadContentBlock] {
        try ForumThreadHTMLBlockParser.parseBlocks(
            fromHTML: html, style: style ?? currentStyle, alignment: alignment ?? currentAlignment,
            paragraphStyle: paragraphStyle ?? currentParagraphStyle, linkURL: currentLinkURL
        )
    }

    private func listMarker() -> String {
        guard let context = lists.last else { return "•" }
        if context.nextNumber < Int.max { lists[lists.count - 1].nextNumber += 1 }
        switch context.type {
        case "1": return "\(context.nextNumber)."
        case "a", "A":
            var number = context.nextNumber
            var marker = ""
            while number > 0 {
                number -= 1
                marker = String(UnicodeScalar(97 + number % 26)!) + marker
                number /= 26
            }
            return (context.type == "A" ? marker.uppercased() : marker) + "."
        default: return "•"
        }
    }

    private static func imageDimension(_ value: String) -> Double? {
        guard let number = Double(value), number.isFinite, number > 0 else { return nil }
        return min(number, 10_000)
    }

    private static func verbatimText(in node: Node) -> String {
        if let text = node as? TextNode {
            return text.getWholeText().replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        guard let element = node as? Element else { return "" }
        let tag = element.tagName().lowercased()
        if tag == "br" { return "\n" }
        if tag == "script" || tag == "style" { return "" }
        let text = element.getChildNodes().map { verbatimText(in: $0) }.joined()
        return tag == "li" ? text + "\n" : text
    }

    private func appendCurrentStyleRun(start: Int, length: Int) {
        guard length > 0, !currentStyle.isEmpty else { return }
        if var last = styleRuns.last,
           last.start + last.length == start,
           last.style == currentStyle {
            last.length += length
            styleRuns[styleRuns.count - 1] = last
        } else {
            styleRuns.append(PendingTextStyleRun(start: start, length: length, style: currentStyle))
        }
    }

    private func appendBlock(_ kind: ForumThreadContentBlockKind, seed: String) {
        let id = "\(blockCounter)-\(Self.stableHash(seed))"
        blockCounter += 1
        blocks.append(ForumThreadContentBlock(id: id, kind: kind))
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 5_381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

import Foundation

/// Stateful DOM walker that flattens a sanitized post-body fragment into content blocks.
///
/// Inline markup accumulates into a pending text run (with link/style/ruby ranges);
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
    private var currentLinkURL: URL?
    private var currentStyle = ForumThreadTextStyle()
    private var currentAlignment = ForumThreadTextAlignment.start
    private var blockCounter = 0

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
            try appendQuote(from: element)
        case "div":
            try parseDiv(element)
        case "pre":
            commitText()
            appendBlock(.code(element.text()), seed: "code-\(element.text())")
        case "table":
            try parseTable(element)
        case "ul":
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
        case "ruby":
            try parseRuby(element)
        case "rt":
            return
        case "font":
            try withTextStyle(ForumThreadTextStyleParser.style(fromFontElement: element)) {
                try parseChildren(of: element)
            }
        case "span":
            try withTextStyle(ForumThreadTextStyleParser.style(fromStyleAttribute: element.attr("style"))) {
                try parseChildren(of: element)
            }
        case "p":
            try parseBlockContainer(element)
        case "ol", "tbody", "tr", "td", "th":
            appendLineBreak(maxConsecutive: 1)
            try parseChildren(of: element)
            appendLineBreak(maxConsecutive: 1)
        case "li":
            appendLineBreak(maxConsecutive: 1)
            appendText("• ")
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
            let titleNode = element.select(".showcollapse_title").first()
            let title = titleNode?.text().nilIfBlank
            titleNode?.remove()
            let contentBlocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: element.html())
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
            let contentBlocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: element.html())
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
            appendBlock(.code(element.text()), seed: "code-\(element.text())")
            return
        }

        try parseBlockContainer(element)
    }

    private func parseBlockContainer(_ element: Element) throws {
        let alignment = textAlignment(from: element) ?? currentAlignment
        try withTextAlignment(alignment) {
            appendLineBreak(maxConsecutive: 1)
            try parseChildren(of: element)
            appendLineBreak(maxConsecutive: 1)
        }
    }

    private func parseTable(_ element: Element) throws {
        let rows = element.select("tr").array()
        let isDataTable = rows.contains { row in
            row.select("td, th").array().count > 1
        }
        guard isDataTable else {
            appendLineBreak(maxConsecutive: 1)
            try parseChildren(of: element)
            appendLineBreak(maxConsecutive: 1)
            return
        }

        commitText()
        let tableRows = try rows.map { row in
            try row.select("td, th").array().map { cell in
                let tagName = cell.tagName().lowercased()
                let hasStrongText = !cell.select("strong, b").array().isEmpty
                let isHeader = tagName == "th" || hasStrongText
                return ForumThreadTableCell(
                    isHeader: isHeader,
                    blocks: try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: cell.html())
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

        appendLineBreak(maxConsecutive: 1)
        try parseChildren(of: element)
        appendLineBreak(maxConsecutive: 1)
    }

    private func parseLink(_ element: Element) throws {
        guard let url = HTMLTextExtractor.absoluteURL(from: element.attr("href")) else {
            try parseChildren(of: element)
            return
        }

        let previousLinkURL = currentLinkURL
        currentLinkURL = url
        let start = text.count
        try parseChildren(of: element)
        let end = text.count
        if end > start {
            links.append(PendingTextLink(start: start, length: end - start, url: url))
        } else {
            appendText(element.text())
            let linkTextLength = max(element.text().count, 0)
            if linkTextLength > 0 {
                links.append(PendingTextLink(start: start, length: linkTextLength, url: url))
            }
        }
        currentLinkURL = previousLinkURL
    }

    private func parseRuby(_ element: Element) throws {
        let rubyText = element.children()
            .array()
            .filter { $0.tagName().lowercased() == "rt" }
            .map { $0.text() }
            .joined()
            .nilIfBlank
        let baseText = element.getChildNodes()
            .filter { node in
                guard let childElement = node as? Element else { return true }
                return childElement.tagName().lowercased() != "rt"
            }
            .map { node -> String in
                if let textNode = node as? TextNode {
                    return textNode.text()
                }
                if let childElement = node as? Element {
                    return childElement.text()
                }
                return ""
            }
            .joined()
            .nilIfBlank

        guard let baseText, let rubyText else {
            try parseChildren(of: element)
            return
        }

        let start = text.count
        appendText(baseText)
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
            .quote(try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: quoteContentHTML(from: element))),
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

        commitText()
        appendBlock(
            .image(
                ForumThreadImageBlock(
                    url: url,
                    altText: element.attr("alt"),
                    linkURL: currentLinkURL,
                    isEmoticon: YamiboImageReferenceExtractor.isEmoticonURL(url)
                )
            ),
            seed: "image-\(url.absoluteString)"
        )
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
            case " ", "\n", "\t", "\u{000C}":
                appendCollapsibleSpace()
            default:
                appendText(String(character))
            }
        }
    }

    private func appendText(_ value: String) {
        let decoded = HTMLTextExtractor.decodeHTMLEntities(value)
        guard !decoded.isEmpty else { return }
        let start = text.count
        text += decoded
        appendCurrentStyleRun(start: start, length: decoded.count)
    }

    private func appendLineBreak(maxConsecutive: Int = 2, explicit: Bool = false) {
        guard !text.isEmpty || explicit else { return }
        let trailing = text.reversed().prefix(while: { $0 == "\n" }).count
        if trailing < maxConsecutive {
            text += "\n"
        }
    }

    private func appendCollapsibleSpace() {
        guard let last = text.last else { return }
        if last != " ", last != "\n", last != "\u{3000}" {
            text += " "
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
                    rubies: blockRubies
                )
            ),
            seed: "text-\(normalized.prefix(64))"
        )
        text = ""
        links = []
        styleRuns = []
        rubies = []
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
        switch element.attr("align").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

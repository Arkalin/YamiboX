import Foundation

/// Turns a post body's HTML into renderable `ForumThreadContentBlock`s.
///
/// This is the pipeline entry: it sanitizes the fragment (jammer/hidden nodes),
/// walks the DOM with `ForumThreadBlockBuilder`, and post-processes the result
/// (recursive normalization plus splitting long text blocks for lazy rendering).
enum ForumThreadHTMLBlockParser {
    static func parseBlocks(in body: Element) throws -> [ForumThreadContentBlock] {
        let copy = try KannaSoup.parseBodyFragment(try body.html(), baseURL: YamiboDomain.baseURL.absoluteString)
        try sanitize(copy.body() ?? copy)
        return normalizeBlocks(try ForumThreadBlockBuilder().parse(nodes: (copy.body() ?? copy).getChildNodes()))
    }

    static func parseBlocks(fromHTML html: String) throws -> [ForumThreadContentBlock] {
        let document = try KannaSoup.parseBodyFragment(html, baseURL: YamiboDomain.baseURL.absoluteString)
        try sanitize(document.body() ?? document)
        return normalizeBlocks(try ForumThreadBlockBuilder().parse(nodes: (document.body() ?? document).getChildNodes()))
    }

    /// The whitespace/newline normalization applied to every committed text run,
    /// for callers that need to align externally stored text with parsed blocks.
    static func normalizeCommittedText(_ value: String) -> String {
        ForumThreadTextNormalizer.normalize(value).text
    }

    private static func sanitize(_ element: Element) throws {
        try element.select("font.jammer, .jammer").remove()
        for styledElement in try element.select("[style]").array() {
            let style = try styledElement.attr("style").lowercased().replacingOccurrences(of: " ", with: "")
            if style.contains("display:none") {
                try styledElement.remove()
            }
        }
    }

    private static func normalizeBlocks(_ blocks: [ForumThreadContentBlock]) -> [ForumThreadContentBlock] {
        blocks.flatMap(normalizedBlock)
    }

    private static func normalizedBlock(_ block: ForumThreadContentBlock) -> [ForumThreadContentBlock] {
        switch block.kind {
        case let .text(textBlock):
            splitTextBlock(blockID: block.id, block: textBlock)
        case let .quote(blocks):
            [ForumThreadContentBlock(id: block.id, kind: .quote(normalizeBlocks(blocks)))]
        case let .collapse(title, blocks):
            [ForumThreadContentBlock(id: block.id, kind: .collapse(title: title, contentBlocks: normalizeBlocks(blocks)))]
        case let .locked(cost, blocks):
            [ForumThreadContentBlock(id: block.id, kind: .locked(cost: cost, contentBlocks: normalizeBlocks(blocks)))]
        case let .table(rows):
            [
                ForumThreadContentBlock(
                    id: block.id,
                    kind: .table(
                        rows: rows.map { row in
                            row.map { cell in
                                ForumThreadTableCell(
                                    isHeader: cell.isHeader,
                                    blocks: normalizeBlocks(cell.blocks)
                                )
                            }
                        }
                    )
                )
            ]
        default:
            [block]
        }
    }

    private static func splitTextBlock(
        blockID: String,
        block: ForumThreadTextBlock,
        maxCharacters: Int = 320
    ) -> [ForumThreadContentBlock] {
        let characters = Array(block.text)
        guard characters.count > maxCharacters else {
            return [ForumThreadContentBlock(id: blockID, kind: .text(block))]
        }

        var chunks: [ForumThreadContentBlock] = []
        var start = 0
        while start < characters.count {
            let preferredEnd = min(start + maxCharacters, characters.count)
            let end: Int
            if preferredEnd < characters.count,
               let newlineIndex = characters[start ..< preferredEnd].lastIndex(of: "\n"),
               newlineIndex > start + maxCharacters / 3 {
                end = newlineIndex + 1
            } else {
                end = preferredEnd
            }

            let chunkText = String(characters[start ..< end])
            let chunkLinks = block.links.compactMap { link -> ForumThreadTextLink? in
                let linkStart = link.start
                let linkEnd = link.start + link.length
                let overlapStart = max(start, linkStart)
                let overlapEnd = min(end, linkEnd)
                guard overlapEnd > overlapStart else { return nil }
                return ForumThreadTextLink(
                    start: overlapStart - start,
                    length: overlapEnd - overlapStart,
                    url: link.url
                )
            }
            let chunkStyleRuns = block.styleRuns.compactMap { run -> ForumThreadTextStyleRun? in
                let runStart = run.start
                let runEnd = run.start + run.length
                let overlapStart = max(start, runStart)
                let overlapEnd = min(end, runEnd)
                guard overlapEnd > overlapStart else { return nil }
                return ForumThreadTextStyleRun(
                    start: overlapStart - start,
                    length: overlapEnd - overlapStart,
                    style: run.style
                )
            }
            let chunkRubies = block.rubies.compactMap { ruby -> ForumThreadRubyText? in
                let rubyStart = ruby.start
                let rubyEnd = ruby.start + ruby.length
                guard rubyStart >= start, rubyEnd <= end else { return nil }
                return ForumThreadRubyText(
                    start: rubyStart - start,
                    length: ruby.length,
                    baseText: ruby.baseText,
                    rubyText: ruby.rubyText
                )
            }
            chunks.append(
                ForumThreadContentBlock(
                    id: start == 0 ? blockID : "\(blockID)-\(start)",
                    kind: .text(
                        ForumThreadTextBlock(
                            text: chunkText,
                            alignment: block.alignment,
                            links: chunkLinks,
                            styleRuns: chunkStyleRuns,
                            rubies: chunkRubies
                        )
                    )
                )
            )
            start = end
        }
        return chunks
    }
}

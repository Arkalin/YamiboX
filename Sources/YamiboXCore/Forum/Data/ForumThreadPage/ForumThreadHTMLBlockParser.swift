import Foundation

/// Turns a post body's HTML into renderable `ForumThreadContentBlock`s.
///
/// This is the pipeline entry: it sanitizes the fragment (jammer/hidden nodes)
/// and walks the DOM with `ForumThreadBlockBuilder`. Text blocks follow content
/// structure rather than an artificial character limit.
enum ForumThreadHTMLBlockParser {
    // Bump when cached content blocks need to be rebuilt from their HTML.
    static let cacheVersion = 1

    static func parseBlocks(in body: Element) throws -> [ForumThreadContentBlock] {
        let copy = try KannaSoup.parseBodyFragment(body.html(), baseURL: YamiboDomain.baseURL.absoluteString)
        sanitize(copy.body() ?? copy)
        return try ForumThreadBlockBuilder().parse(nodes: (copy.body() ?? copy).getChildNodes())
    }

    static func parseBlocks(
        fromHTML html: String,
        style: ForumThreadTextStyle = ForumThreadTextStyle(),
        alignment: ForumThreadTextAlignment = .start,
        paragraphStyle: ForumThreadParagraphStyle? = nil,
        linkURL: URL? = nil
    ) throws -> [ForumThreadContentBlock] {
        let document = try KannaSoup.parseBodyFragment(html, baseURL: YamiboDomain.baseURL.absoluteString)
        sanitize(document.body() ?? document)
        return try ForumThreadBlockBuilder(style: style, alignment: alignment, paragraphStyle: paragraphStyle, linkURL: linkURL)
            .parse(nodes: (document.body() ?? document).getChildNodes())
    }

    /// The whitespace/newline normalization applied to every committed text run,
    /// for callers that need to align externally stored text with parsed blocks.
    static func normalizeCommittedText(_ value: String) -> String {
        ForumThreadTextNormalizer.normalize(value).text
    }

    private static func sanitize(_ element: Element) {
        element.select("font.jammer, .jammer").remove()
        for styledElement in element.select("[style]").array() {
            let style = styledElement.attr("style").lowercased().replacingOccurrences(of: " ", with: "")
            if style.contains("display:none") {
                styledElement.remove()
            }
        }
    }
}

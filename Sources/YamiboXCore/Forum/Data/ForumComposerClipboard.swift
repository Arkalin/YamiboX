import Foundation

public enum ForumComposerClipboard {
    /// Parse with the existing DOM adapter, not NSAttributedString's HTML importer.
    /// Images and executable elements never cause requests during a paste.
    public static func importHTML(_ html: String) throws -> String {
        guard html.utf8.count <= 2 * 1024 * 1024 else { throw ForumPageError.fieldTooLong("HTML", 2 * 1024 * 1024) }
        let document = try KannaSoup.parseBodyFragment(html)
        document.select("script, style, iframe, object, embed, meta, link, form, input, button, textarea").remove()
        func wrap(_ tag: ForumComposerTag, _ body: String, parameter: String = "") -> String {
            (try? ForumComposerSyntax.markup(tag: tag, parameter: parameter, body: body)) ?? body
        }
        func walk(_ node: Node, depth: Int) -> String {
            guard depth < 64 else { return node.text() }
            guard let element = node as? Element else { return node.text() }
            let name = element.tagName().lowercased()
            let body = element.getChildNodes().map { walk($0, depth: depth + 1) }.joined()
            var result: String
            switch name {
            case "b", "strong": result = wrap(.b, body)
            case "i", "em": result = wrap(.i, body)
            case "u": result = wrap(.u, body)
            case "s", "strike", "del": result = wrap(.s, body)
            case "sup": result = wrap(.sup, body)
            case "sub": result = wrap(.sub, body)
            case "br": result = "\n"
            case "hr": result = "[hr]"
            case "blockquote": result = wrap(.quote, body)
            case "pre": result = wrap(.code, element.getChildNodes().map { $0.text() }.joined())
            case "a":
                if let url = ForumComposerSyntax.safeURL(element.attr("href")) { result = wrap(.url, body, parameter: url.absoluteString) }
                else { result = body }
            case "img": result = element.attr("alt")
            case "ul": result = wrap(.list, body)
            case "ol": result = wrap(.list, body, parameter: ["1", "a", "A"].contains(element.attr("type")) ? element.attr("type") : "1")
            case "li": result = "[*]" + body + "\n"
            case "table": result = wrap(.table, body)
            case "tr": result = wrap(.tr, body)
            case "td", "th":
                let columns = min(max(Int(element.attr("colspan")) ?? 1, 1), 100)
                let rows = min(max(Int(element.attr("rowspan")) ?? 1, 1), 100)
                result = wrap(.td, body, parameter: columns == 1 && rows == 1 ? "" : "\(columns),\(rows)")
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6": result = body + "\n"
            default: result = body
            }
            if name == "span" || name == "font" || name == "p" || name == "div" {
                let style = name == "font" ? ForumThreadTextStyleParser.style(fromFontElement: element) : ForumThreadTextStyleParser.style(fromStyleAttribute: element.attr("style"))
                if style.isBold { result = wrap(.b, result) }
                if style.isItalic { result = wrap(.i, result) }
                if style.isUnderline { result = wrap(.u, result) }
                if style.isStrikethrough { result = wrap(.s, result) }
                if let color = style.foregroundHex { result = wrap(.color, result, parameter: color) }
                if let color = style.backgroundHex { result = wrap(.backcolor, result, parameter: color) }
                if let size = style.relativeFontSize { result = wrap(.size, result, parameter: ForumComposerLength.number(size * 17) + "px") }
                if name == "font", !element.attr("face").isEmpty { result = wrap(.font, result, parameter: element.attr("face")) }
                if let alignment = ForumComposerAlignment(rawValue: element.attr("align")) { result = wrap(.align, result, parameter: alignment.rawValue) }
            }
            return result
        }
        return (document.body() ?? document).getChildNodes().map { walk($0, depth: 0) }.joined()
    }
}

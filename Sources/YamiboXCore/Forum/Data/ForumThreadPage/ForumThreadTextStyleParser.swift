import Foundation

/// Adapts parsed HTML elements to domain text styles.
enum ForumThreadTextStyleParser {
    /// Style carried by a `<font color=... size=... style=...>` element.
    static func style(fromFontElement element: Element) -> ForumThreadTextStyle {
        var result = ForumThreadTextStyle()
        result.fontFamily = element.attr("face").nilIfBlank
        if let color = ForumTextStyleRules.normalizedColorHex(element.attr("color")) {
            result.foregroundHex = color
        }
        if let fontSize = ForumTextStyleRules.relativeFontSize(fromHTMLSize: element.attr("size")) {
            result.relativeFontSize = fontSize
        }
        return result.merged(with: ForumTextStyleRules.style(fromStyleAttribute: element.attr("style")))
    }

    static func paragraphStyle(from element: Element, inheriting inherited: ForumThreadParagraphStyle?) -> ForumThreadParagraphStyle? {
        let declarations = ForumTextStyleRules.styleDeclarations(from: element.attr("style"))
        var result = inherited ?? ForumThreadParagraphStyle()
        if let height = declarations["line-height"]?.lowercased() {
            if height == "normal" {
                result.lineHeight = nil
                result.lineHeightMultiple = nil
            } else if let value = ForumTextStyleRules.cssPixels(height), value > 0 {
                result.lineHeight = value
                result.lineHeightMultiple = nil
            } else if let value = Double(height.replacingOccurrences(of: "em", with: "").replacingOccurrences(of: "%", with: "")),
                      value.isFinite, value > 0 {
                result.lineHeight = nil
                result.lineHeightMultiple = height.hasSuffix("%") ? value / 100 : value
            }
        }
        if let indent = declarations["text-indent"]?.lowercased() {
            if indent.hasSuffix("em"), let value = Double(indent.dropLast(2)), value.isFinite {
                result.firstLineIndentEm = value
                result.firstLineIndentPixels = nil
            } else if let value = ForumTextStyleRules.cssPixels(indent) {
                result.firstLineIndentPixels = value
                result.firstLineIndentEm = nil
            }
        }
        return result == ForumThreadParagraphStyle() ? nil : result
    }
}

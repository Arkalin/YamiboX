import Foundation

enum ForumComposerMarkupParser {
    private struct Token {
        let range: NSRange
        let raw: String
        let name: String
        let isClosing: Bool
        let parameter: String
        let element: Element?
    }

    private static let emoticons = Dictionary(uniqueKeysWithValues: ForumEmoticonCatalog.categories.flatMap(\.items).map { ($0.code, $0.imageURL) })
    private static let inlineNames: Set<String> = ["b", "strong", "i", "em", "u", "s", "strike", "quote", "blockquote", "url", "a", "color", "size", "font", "span"]
    private static let opaqueNames: Set<String> = ["code", "hide", "table", "iframe", "script", "style", "audio", "video", "ruby"]

    static func parse(_ source: String, format: ForumComposerFormat) -> [ForumComposerRun] {
        guard format != .plainText else {
            return [.init(text: source, source: ForumComposerMarkup.escapeHTML(source))]
        }
        let text = source as NSString
        let pattern = format == .html
            ? #"<!--[\s\S]*?-->|<(?:[^>"']|"[^"]*"|'[^']*')+>"#
            : #"\[/?[a-zA-Z][a-zA-Z0-9]*(?:=[^\]\r\n]*)?\]|\{:[^{}\s]+:\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [.init(text: source, source: source)] }
        let tokens = expression.matches(in: source, range: NSRange(location: 0, length: text.length)).map { match -> Token in
            let raw = text.substring(with: match.range)
            let inner = String(raw.dropFirst().dropLast())
            let isClosing = inner.hasPrefix("/")
            let body = isClosing ? String(inner.dropFirst()) : inner
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
            let parameter = body.firstIndex(of: "=").map { String(body[body.index(after: $0)...]) } ?? ""
            // Reuse the project's HTML parser for attributes/entities, never
            // evaluate HTML or use WebKit's attributed-string importer.
            let element = format == .html && !isClosing ? (try? KannaSoup.parseBodyFragment(raw).selectFirst(name)) : nil
            return Token(range: match.range, raw: raw, name: name, isClosing: isClosing, parameter: parameter, element: element ?? nil)
        }
        var matching: [Int: Int] = [:]
        var stack: [Int] = []
        for (index, token) in tokens.enumerated() {
            guard !token.name.isEmpty, !["br", "img", "hr", "input", "meta", "link"].contains(token.name) || format == .bbcode else { continue }
            if token.isClosing {
                if let opening = stack.last, tokens[opening].name == token.name {
                    matching[opening] = index
                    stack.removeLast()
                }
            } else if !token.raw.hasSuffix("/>") {
                stack.append(index)
            }
        }

        var runs: [ForumComposerRun] = []
        func appendText(_ range: NSRange, wrappers: [ForumComposerWrapper], literal: Bool = false) {
            guard range.length > 0 else { return }
            let raw = text.substring(with: range)
            let value: String
            if format == .html && !literal {
                // RCDATA decodes named/numeric entities once without folding
                // whitespace, unlike the reader's display-text normalizer.
                let node = try? KannaSoup.parseBodyFragment("<textarea>\(raw)</textarea>").selectFirst("textarea")
                value = node?.getChildNodes().map { $0.text() }.joined() ?? raw
            } else { value = raw }
            runs.append(.init(text: value, source: raw, wrappers: wrappers, isLiteral: literal))
        }

        func walk(from start: Int, to end: Int, lower: Int, upper: Int, wrappers: [ForumComposerWrapper], depth: Int) {
            guard depth < 64 else { appendText(NSRange(location: lower, length: upper - lower), wrappers: wrappers, literal: true); return }
            var cursor = lower
            var index = start
            while index < end {
                let token = tokens[index]
                appendText(NSRange(location: cursor, length: max(0, token.range.location - cursor)), wrappers: wrappers)
                let tokenEnd = NSMaxRange(token.range)
                if let imageURL = emoticons[token.raw], format == .bbcode {
                    runs.append(.init(text: "\u{FFFC}", source: token.raw, wrappers: wrappers, imageURL: imageURL, isAttachment: true))
                } else if token.name == "br" && format == .html {
                    runs.append(.init(text: "\n", source: token.raw, wrappers: wrappers))
                } else if token.name == "img" && format == .html, let element = token.element,
                          let url = imageURL(element.attr("src")) {
                    runs.append(.init(text: "\u{FFFC}", source: token.raw, wrappers: wrappers, imageURL: url, isAttachment: true))
                } else if let closeIndex = matching[index], closeIndex < end {
                    let close = tokens[closeIndex]
                    let fullRange = NSRange(location: token.range.location, length: NSMaxRange(close.range) - token.range.location)
                    let innerRange = NSRange(location: tokenEnd, length: close.range.location - tokenEnd)
                    if format == .bbcode && ["img", "attach", "attachimg"].contains(token.name) {
                        let url = token.name == "img" ? imageURL(text.substring(with: innerRange)) : nil
                        runs.append(.init(text: "\u{FFFC}", source: text.substring(with: fullRange), wrappers: wrappers, imageURL: url, isAttachment: true))
                    } else if opaqueNames.contains(token.name) || innerRange.length == 0 {
                        appendText(fullRange, wrappers: wrappers, literal: true)
                    } else if format == .html && ["p", "div"].contains(token.name) && token.element?.attributes.isEmpty == true {
                        walk(from: index + 1, to: closeIndex, lower: tokenEnd, upper: close.range.location, wrappers: wrappers, depth: depth + 1)
                        // TextKit edits paragraph boundaries as ordinary line
                        // breaks. After an edit these canonicalize to <br>.
                        runs.append(.init(text: "\n", source: "<br>", wrappers: wrappers))
                    } else if let wrapper = wrapper(token, closing: close.raw, inner: text.substring(with: innerRange), format: format) {
                        walk(from: index + 1, to: closeIndex, lower: tokenEnd, upper: close.range.location, wrappers: wrappers + [wrapper], depth: depth + 1)
                    } else {
                        appendText(fullRange, wrappers: wrappers, literal: true)
                    }
                    cursor = NSMaxRange(close.range)
                    index = closeIndex + 1
                    continue
                } else {
                    appendText(token.range, wrappers: wrappers, literal: true)
                }
                cursor = tokenEnd
                index += 1
            }
            appendText(NSRange(location: cursor, length: max(0, upper - cursor)), wrappers: wrappers)
        }
        walk(from: 0, to: tokens.count, lower: 0, upper: text.length, wrappers: [], depth: 0)
        return runs
    }

    private static func wrapper(_ token: Token, closing: String, inner: String, format: ForumComposerFormat) -> ForumComposerWrapper? {
        guard inlineNames.contains(token.name) else { return nil }
        var style = ForumThreadTextStyle()
        switch token.name {
        case "b", "strong": style.isBold = true
        case "i", "em": style.isItalic = true
        case "u": style.isUnderline = true
        case "s", "strike": style.isStrikethrough = true
        case "color": style.foregroundHex = ForumThreadTextStyleParser.normalizedColorHex(token.parameter)
        case "size": style.relativeFontSize = ForumThreadTextStyleParser.relativeFontSize(fromHTMLSize: token.parameter)
        case "font" where format == .html:
            if let element = token.element { style = ForumThreadTextStyleParser.style(fromFontElement: element) }
        case "span":
            if let element = token.element { style = ForumThreadTextStyleParser.style(fromStyleAttribute: element.attr("style")) }
        default: break
        }
        var link: URL?
        if token.name == "url" { link = imageURL(token.parameter.isEmpty ? inner : token.parameter) }
        if token.name == "a" { link = imageURL(token.element?.attr("href") ?? "") }
        return ForumComposerWrapper(id: "source-\(token.range.location)", name: token.name, opening: token.raw, closing: closing,
                                    style: style, link: link, isQuote: ["quote", "blockquote"].contains(token.name))
    }

    private static func imageURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return ForumWebPagePolicy.secureURL(url)
    }
}

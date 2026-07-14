import Foundation
import Kanna

enum KannaSoup {
    static func parse(_ html: String, baseURL: String? = nil) throws -> Document {
        try Document(document: HTML(html: html, url: baseURL, encoding: .utf8))
    }

    static func parseBodyFragment(_ html: String, baseURL: String? = nil) throws -> Document {
        try parse("<body>\(html)</body>", baseURL: baseURL)
    }
}

class Node {
    fileprivate let rawNode: any Kanna.XMLElement

    fileprivate init(rawNode: any Kanna.XMLElement) {
        self.rawNode = rawNode
    }

    func getChildNodes() -> [Node] {
        rawNode.xpath("child::node()").map(Self.wrap)
    }

    func text() throws -> String {
        rawNode.text ?? ""
    }

    fileprivate static func wrap(_ rawNode: any Kanna.XMLElement) -> Node {
        rawNode.tagName == nil || rawNode.tagName == "text" ? TextNode(rawNode: rawNode) : Element(rawNode: rawNode)
    }
}

final class TextNode: Node {
    override func text() -> String {
        rawNode.text ?? ""
    }

    func getWholeText() -> String {
        text()
    }
}

class Element: Node {
    private static let blockTextTags: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p",
        "pre", "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"
    ]

    func select(_ selector: String) throws -> Elements {
        Elements(Self.selectElements(selector, in: rawNode))
    }

    override func text() throws -> String {
        Self.normalizedText(renderedText())
    }

    func attr(_ name: String) throws -> String {
        rawNode[name] ?? ""
    }

    func html() throws -> String {
        rawNode.innerHTML ?? ""
    }

    func outerHtml() throws -> String {
        rawNode.toHTML ?? ""
    }

    func ownText() -> String {
        rawNode.xpath("child::text()")
            .map { $0.text ?? "" }
            .joined()
    }

    func tagName() -> String {
        rawNode.tagName ?? ""
    }

    func id() -> String {
        rawNode["id"] ?? ""
    }

    func className() throws -> String {
        rawNode.className ?? ""
    }

    func hasClass(_ className: String) -> Bool {
        let classes = (rawNode.className ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return classes.contains(className)
    }

    func parent() -> Element? {
        rawNode.parent.map { Element(rawNode: $0) }
    }

    func parents() -> [Element] {
        var result: [Element] = []
        var current = parent()
        while let element = current {
            result.append(element)
            current = element.parent()
        }
        return result
    }

    func nextElementSibling() throws -> Element? {
        rawNode.nextSibling.map { Element(rawNode: $0) }
    }

    func previousElementSibling() throws -> Element? {
        rawNode.previousSibling.map { Element(rawNode: $0) }
    }

    func children() -> Elements {
        Elements(rawNode.children.map { Element(rawNode: $0) })
    }

    func remove() throws {
        rawNode.parent?.removeChild(rawNode)
    }

    func isSameDOMNode(as other: Element) -> Bool {
        if let id = try? attr("id"), !id.isEmpty {
            return id == ((try? other.attr("id")) ?? "")
                && tagName() == other.tagName()
        }
        return (try? outerHtml()) == (try? other.outerHtml())
    }

    func cssSelector() throws -> String {
        var parts: [String] = []
        var current: Element? = self
        while let element = current {
            let tag = element.tagName()
            guard !tag.isEmpty else { break }
            let id = element.id()
            if !id.isEmpty {
                parts.append("\(tag)#\(id)")
                break
            }

            let siblings = element.parent()?.children().array().filter { $0.tagName() == tag } ?? []
            if siblings.count > 1,
               let index = siblings.firstIndex(where: { $0.isSameDOMNode(as: element) }) {
                parts.append("\(tag):nth-of-type(\(index + 1))")
            } else {
                parts.append(tag)
            }
            current = element.parent()
        }
        return parts.reversed().joined(separator: " > ")
    }

    private func renderedText() -> String {
        let tag = tagName().lowercased()
        if tag == "br" {
            return "\n"
        }
        if tag == "script" || tag == "style" {
            return ""
        }

        var value = ""
        for child in getChildNodes() {
            if let textNode = child as? TextNode {
                value += textNode.text()
                continue
            }
            guard let element = child as? Element else {
                continue
            }
            let childTag = element.tagName().lowercased()
            let childText = element.renderedText()
            guard !childText.isEmpty else { continue }
            if Self.blockTextTags.contains(childTag), !value.isEmpty, !value.last!.isWhitespace {
                value += " "
            }
            value += childText
            if Self.blockTextTags.contains(childTag), !value.isEmpty, !value.last!.isWhitespace {
                value += " "
            }
        }
        return value
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func selectElements(_ selector: String, in searchable: any Kanna.Searchable) -> [Element] {
        let selectorParts = splitSelectorList(selector)
        guard selectorParts.count > 1 else {
            return selectorParts.flatMap { selectSingleSelector($0, in: searchable) }
        }

        let selected = selectorParts.flatMap { selectSingleSelector($0, in: searchable) }
        let broadSelector = selectorParts.map(broadSelectorForOrdering).joined(separator: ", ")
        let orderedCandidates = searchable.css(broadSelector).map { Element(rawNode: $0) }
        guard !orderedCandidates.isEmpty else { return selected }
        return orderedCandidates.filter { candidate in
            selected.contains { $0.isSameDOMNode(as: candidate) }
        }
    }

    private static func selectSingleSelector(_ selector: String, in searchable: any Kanna.Searchable) -> [Element] {
        if !containsTopLevelCombinator(selector) {
            let descendantParts = splitDescendantSelector(selector)
            if descendantParts.count > 1 {
                let first = descendantParts[0]
                let rest = descendantParts.dropFirst().joined(separator: " ")
                return selectSingleSelector(first, in: searchable).flatMap { element in
                    (try? element.select(rest).array()) ?? []
                }
            }
        }

        let conditions = attributeConditions(in: selector)
        guard conditions.count > 1,
              attributeConditionsBelongToSameSimpleSelector(conditions, in: selector) else {
            return searchable.css(selector).map { Element(rawNode: $0) }
        }

        let prefix = String(selector[..<conditions[0].range.lowerBound])
        let broadSelector = prefix + conditions[0].raw
        return searchable.css(broadSelector)
            .map { Element(rawNode: $0) }
            .filter { element in
                conditions.allSatisfy { $0.matches(element: element) }
            }
    }

    private static func broadSelectorForOrdering(_ selector: String) -> String {
        let conditions = attributeConditions(in: selector)
        guard conditions.count > 1,
              attributeConditionsBelongToSameSimpleSelector(conditions, in: selector) else {
            return selector
        }

        let prefix = String(selector[..<conditions[0].range.lowerBound])
        return prefix + conditions[0].raw
    }

    private static func splitSelectorList(_ selector: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var bracketDepth = 0
        var parenDepth = 0
        var quote: Character?

        for character in selector {
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case "[":
                bracketDepth += 1
                current.append(character)
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            case "(":
                parenDepth += 1
                current.append(character)
            case ")":
                parenDepth = max(0, parenDepth - 1)
                current.append(character)
            case "," where bracketDepth == 0 && parenDepth == 0:
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
                current = ""
            default:
                current.append(character)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts
    }

    private static func splitDescendantSelector(_ selector: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var bracketDepth = 0
        var parenDepth = 0
        var quote: Character?

        for character in selector {
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case "[":
                bracketDepth += 1
                current.append(character)
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            case "(":
                parenDepth += 1
                current.append(character)
            case ")":
                parenDepth = max(0, parenDepth - 1)
                current.append(character)
            case let character where character.isWhitespace && bracketDepth == 0 && parenDepth == 0:
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
                current = ""
            default:
                current.append(character)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts
    }

    private static func containsTopLevelCombinator(_ selector: String) -> Bool {
        var bracketDepth = 0
        var parenDepth = 0
        var quote: Character?
        for character in selector {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "(":
                parenDepth += 1
            case ")":
                parenDepth = max(0, parenDepth - 1)
            case let character where (character == ">" || character == "+" || character == "~") && bracketDepth == 0 && parenDepth == 0:
                return true
            default:
                continue
            }
        }
        return false
    }

    private struct AttributeCondition {
        let raw: String
        let range: Range<String.Index>
        let name: String
        let operation: String
        let value: String

        func matches(element: Element) -> Bool {
            let attribute = ((try? element.attr(name)) ?? "")
            switch operation {
            case "*=":
                return attribute.contains(value)
            case "^=":
                return attribute.hasPrefix(value)
            case "$=":
                return attribute.hasSuffix(value)
            case "=":
                return attribute == value
            default:
                return false
            }
        }
    }

    private static func attributeConditions(in selector: String) -> [AttributeCondition] {
        var conditions: [AttributeCondition] = []
        var index = selector.startIndex
        while let open = selector[index...].firstIndex(of: "["),
              let close = selector[open...].firstIndex(of: "]") {
            let rawRange = open ... close
            let bodyStart = selector.index(after: open)
            let body = String(selector[bodyStart ..< close])
            if let condition = attributeCondition(body: body, raw: String(selector[rawRange]), range: open ..< selector.index(after: close)) {
                conditions.append(condition)
            }
            index = selector.index(after: close)
        }
        return conditions
    }

    private static func attributeConditionsBelongToSameSimpleSelector(
        _ conditions: [AttributeCondition],
        in selector: String
    ) -> Bool {
        guard conditions.count > 1 else { return false }
        for pair in zip(conditions, conditions.dropFirst()) {
            let between = selector[pair.0.range.upperBound ..< pair.1.range.lowerBound]
            if between.contains(where: { $0.isWhitespace || $0 == ">" || $0 == "+" || $0 == "~" }) {
                return false
            }
        }
        return true
    }

    private static func attributeCondition(body: String, raw: String, range: Range<String.Index>) -> AttributeCondition? {
        let operations = ["*=", "^=", "$=", "="]
        guard let operation = operations.first(where: { body.contains($0) }),
              let operationRange = body.range(of: operation) else {
            return nil
        }
        let name = body[..<operationRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = body[operationRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "'" || first == "\""),
           first == last {
            value.removeFirst()
            value.removeLast()
        }
        guard !name.isEmpty else { return nil }
        return AttributeCondition(raw: raw, range: range, name: name, operation: operation, value: value)
    }
}

final class Document: Element {
    private let rawDocument: any Kanna.HTMLDocument

    fileprivate init(document: any Kanna.HTMLDocument) throws {
        self.rawDocument = document
        guard let root = document.at_xpath("/*") else {
            throw Kanna.ParseError.Empty
        }
        super.init(rawNode: root)
    }

    override func select(_ selector: String) throws -> Elements {
        Elements(Element.selectElements(selector, in: rawDocument))
    }

    override func text() throws -> String {
        try (body() ?? self).text()
    }

    override func html() throws -> String {
        rawDocument.toHTML ?? ""
    }

    func title() throws -> String {
        rawDocument.title ?? ""
    }

    func body() -> Element? {
        rawDocument.body.map { Element(rawNode: $0) }
    }
}

struct Elements: Sequence {
    private var elements: [Element]

    init(_ elements: [Element] = []) {
        self.elements = elements
    }

    func makeIterator() -> Array<Element>.Iterator {
        elements.makeIterator()
    }

    subscript(index: Int) -> Element {
        elements[index]
    }

    var count: Int {
        elements.count
    }

    func first() -> Element? {
        elements.first
    }

    func last() -> Element? {
        elements.last
    }

    func array() -> [Element] {
        elements
    }

    var isEmpty: Bool {
        elements.isEmpty
    }

    func select(_ selector: String) throws -> Elements {
        Elements(try elements.flatMap { try $0.select(selector).array() })
    }

    func text() throws -> String {
        try elements.map { try $0.text() }.joined()
    }

    func html() throws -> String {
        try elements.map { try $0.outerHtml() }.joined()
    }

    func remove() throws {
        for element in elements {
            try element.remove()
        }
    }
}

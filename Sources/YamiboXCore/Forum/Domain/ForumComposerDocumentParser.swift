import Foundation

enum ForumComposerDocumentParser {
    struct Result { var nodes: [ForumComposerNode]; var diagnostics: [ForumComposerDiagnostic] }
    private struct Token {
        let range: NSRange
        let raw: String
        let name: String
        let parameter: String
        let closing: Bool
        let emoticon: Bool
        var tag: ForumComposerTag? { ForumComposerTag.named(name) }
    }

    private static let expression = try! NSRegularExpression(pattern: #"\[/?(?:[a-zA-Z][a-zA-Z0-9]*(?:=[^\]\r\n]*)?|\*|#[0-9]+(?:,[0-9]+)?)\]|\{:[^{}\s]+:\}"#)
    private static let emoticons = Set(ForumEmoticonCatalog.categories.flatMap(\.items).map(\.code))

    static func parse(_ source: String) -> Result {
        let text = source as NSString
        let tokens = expression.matches(in: source, range: NSRange(location: 0, length: text.length)).map { match -> Token in
            let raw = text.substring(with: match.range)
            let inner = String(raw.dropFirst().dropLast())
            let closing = inner.hasPrefix("/")
            let body = closing ? String(inner.dropFirst()) : inner
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return Token(range: match.range, raw: raw,
                         name: body.hasPrefix("#") ? "#" : String(parts[0]).lowercased(),
                         parameter: body.hasPrefix("#") ? String(body.dropFirst()) : (parts.count == 2 ? String(parts[1]) : ""),
                         closing: closing, emoticon: emoticons.contains(raw))
        }
        var pairs: [Int: Int] = [:]
        var crossed: [Int: Int] = [:]
        // Literal bodies use the nearest closing tag, even when their contents
        // contain markup. Index it once rather than searching every suffix.
        var literalClosings: [Int: Int] = [:]
        var nextClosingByName: [String: Int] = [:]
        for index in tokens.indices.reversed() {
            let token = tokens[index]
            if token.closing { nextClosingByName[token.name] = index }
            else if token.tag?.isLiteralBody == true {
                literalClosings[index] = nextClosingByName[token.name]
            }
        }
        var stack: [Int] = []
        var positionsByName: [String: [Int]] = [:]
        func removeStackSuffix(from position: Int) {
            for opening in stack[position...] {
                positionsByName[tokens[opening].name]?.removeLast()
            }
            stack.removeSubrange(position...)
        }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.emoticon || token.tag?.isSingleton == true { index += 1; continue }
            if token.closing {
                if let last = stack.last, tokens[last].name == token.name {
                    pairs[last] = index
                    removeStackSuffix(from: stack.count - 1)
                } else if let position = positionsByName[token.name]?.last {
                    let first = stack[position]
                    crossed[first] = index
                    for opening in stack[position...] { pairs[opening] = nil }
                    removeStackSuffix(from: position)
                }
            } else if token.tag?.isLiteralBody == true,
                      let close = literalClosings[index] {
                pairs[index] = close
                index = close + 1
                continue
            } else {
                positionsByName[token.name, default: []].append(stack.count)
                stack.append(index)
            }
            index += 1
        }

        var diagnostics: [ForumComposerDiagnostic] = []
        func node(_ range: NSRange, kind: ForumComposerNode.Kind) -> ForumComposerNode {
            .init(kind: kind, range: .init(range))
        }
        func walk(_ start: Int, _ end: Int, lower: Int, upper: Int, depth: Int) -> [ForumComposerNode] {
            guard lower < upper || start < end else { return [] }
            if depth >= 64 {
                let range = ForumComposerRange(location: lower, length: upper - lower)
                diagnostics.append(.init(range: range, reason: .depthLimit))
                return [.init(kind: .opaque, range: range)]
            }
            var result: [ForumComposerNode] = []
            var cursor = lower
            var index = start
            while index < end {
                let token = tokens[index]
                if token.range.location > cursor { result.append(node(NSRange(location: cursor, length: token.range.location - cursor), kind: .text)) }
                let tokenEnd = NSMaxRange(token.range)
                if token.emoticon {
                    result.append(node(token.range, kind: .emoticon))
                } else if let closeIndex = crossed[index], closeIndex < end {
                    let range = ForumComposerRange(location: token.range.location, length: NSMaxRange(tokens[closeIndex].range) - token.range.location)
                    result.append(.init(kind: .opaque, range: range))
                    diagnostics.append(.init(range: range, reason: .malformedTag))
                    cursor = range.end
                    index = closeIndex + 1
                    continue
                } else if !token.closing, let tag = token.tag, tag.isSingleton,
                          let attributes = ForumComposerAttributes.parse(tag: tag, parameter: token.parameter) {
                    if tag == .indexEntry {
                        let newline = text.rangeOfCharacter(from: .newlines, range: NSRange(location: tokenEnd, length: upper - tokenEnd)).location
                        let lineEnd = newline == NSNotFound ? upper : newline
                        let content = ForumComposerRange(location: tokenEnd, length: lineEnd - tokenEnd)
                        result.append(.init(kind: .element(tag), range: .init(location: token.range.location, length: lineEnd - token.range.location),
                                            contentRange: content, opening: token.raw, parameter: token.parameter, attributes: attributes,
                                            children: content.length > 0 ? [.init(kind: .text, range: content)] : []))
                        cursor = lineEnd
                        repeat { index += 1 } while index < end && tokens[index].range.location < lineEnd
                        continue
                    }
                    result.append(.init(kind: .element(tag), range: .init(token.range), contentRange: .init(location: tokenEnd),
                                        opening: token.raw, parameter: token.parameter, attributes: attributes))
                } else if let closeIndex = pairs[index], closeIndex < end {
                    let close = tokens[closeIndex]
                    let range = ForumComposerRange(location: token.range.location, length: NSMaxRange(close.range) - token.range.location)
                    let content = ForumComposerRange(location: tokenEnd, length: close.range.location - tokenEnd)
                    if let tag = token.tag, let attributes = ForumComposerAttributes.parse(tag: tag, parameter: token.parameter) {
                        let children = tag.isLiteralBody
                            ? (content.length == 0 ? [] : [ForumComposerNode(kind: .text, range: content)])
                            : walk(index + 1, closeIndex, lower: content.location, upper: content.end, depth: depth + 1)
                        result.append(.init(kind: .element(tag), range: range, contentRange: content, opening: token.raw,
                                            closing: close.raw, parameter: token.parameter, attributes: attributes, children: children))
                    } else {
                        result.append(.init(kind: .opaque, range: range))
                        diagnostics.append(.init(range: range, reason: token.tag == nil ? .unknownTag : .malformedTag))
                    }
                    cursor = range.end
                    index = closeIndex + 1
                    continue
                } else {
                    result.append(node(token.range, kind: .opaque))
                    diagnostics.append(.init(range: .init(token.range), reason: token.tag == nil ? .unknownTag : .malformedTag))
                }
                cursor = tokenEnd
                index += 1
            }
            if cursor < upper { result.append(node(NSRange(location: cursor, length: upper - cursor), kind: .text)) }
            return result
        }
        return .init(nodes: walk(0, tokens.count, lower: 0, upper: text.length, depth: 0), diagnostics: diagnostics)
    }
}

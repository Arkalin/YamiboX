import Foundation

public struct ForumComposerTextAttributes: Equatable, Sendable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var fontName: String?
    public var relativeSize: Double?
    public var pointSize: Double?
    public var foregroundHex: String?
    public var backgroundHex: String?
    public var baseline = 0
    public var alignment: ForumComposerAlignment = .left
    public var lineHeight: Double?
    public var lineHeightMultiple: Double?
    public var firstLineIndent: Double = 0
    public var indentLevel = 0
    public var quoteLevel = 0
    public var listLevel = 0
    public var link: URL?
    public var literal = false
    public init() {}

    mutating func apply(_ node: ForumComposerNode, document: ForumComposerDocument) {
        guard let tag = node.tag else { return }
        switch tag {
        case .b: bold = true
        case .i: italic = true
        case .u: underline = true
        case .s: strikethrough = true
        case .font: fontName = node.parameter
        case .size:
            if case let .fontSize(relative, points) = node.attributes { relativeSize = relative; pointSize = points }
        case .color: if case let .text(value) = node.attributes { foregroundHex = value }
        case .backcolor: if case let .text(value) = node.attributes { backgroundHex = value }
        case .sup: baseline = 1
        case .sub: baseline = -1
        case .align: if case let .alignment(value) = node.attributes { alignment = value }
        case .p:
            if case let .paragraph(value) = node.attributes {
                alignment = value.alignment
                lineHeight = value.lineHeight
                firstLineIndent = value.firstLineIndent ?? 0
            }
        case .lineh: if case let .lineHeight(value) = node.attributes { lineHeightMultiple = value }
        case .indent: indentLevel += 1
        case .quote: quoteLevel += 1
        case .list: listLevel += 1
        case .url, .email:
            link = ForumComposerSyntax.safeURL(node.parameter.isEmpty ? document.substring(node.contentRange) : node.parameter, email: tag == .email)
        default: break
        }
    }
}

public struct ForumComposerSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case text, atomic, boundary, listMarker(String) }
    public var range: ForumComposerRange
    public var sourceRange: ForumComposerRange
    public var nodeID: String
    public var ancestors: [ForumComposerNode]
    public var attributes: ForumComposerTextAttributes
    public var kind: Kind

    public var isAtomic: Bool { kind == .atomic || { if case .listMarker = kind { return true }; return false }() }
}

/// A platform-independent projection supplies TextKit's text and exact source anchors.
public struct ForumComposerProjection: Equatable, Sendable {
    public let text: String
    public let spans: [ForumComposerSpan]

    public init(document: ForumComposerDocument, parsesBBCode: Bool = true, parsesEmoticons: Bool = true) {
        if !parsesBBCode {
            text = document.source
            spans = [.init(range: .init(location: 0, length: text.utf16.count), sourceRange: .init(location: 0, length: text.utf16.count),
                           nodeID: "source", ancestors: [], attributes: .init(), kind: .text)]
            return
        }
        var result = ""
        var spans: [ForumComposerSpan] = []
        var offset = 0
        func append(_ text: String, range: ForumComposerRange, node: ForumComposerNode,
                    ancestors: [ForumComposerNode], attributes: ForumComposerTextAttributes, kind: ForumComposerSpan.Kind) {
            spans.append(.init(range: .init(location: offset, length: text.utf16.count), sourceRange: range,
                               nodeID: node.id, ancestors: ancestors, attributes: attributes, kind: kind))
            result += text
            offset += text.utf16.count
        }
        func boundary(_ node: ForumComposerNode, at location: Int, ancestors: [ForumComposerNode], attributes: ForumComposerTextAttributes) {
            guard !result.isEmpty, !result.hasSuffix("\n") else { return }
            append("\n", range: .init(location: location), node: node, ancestors: ancestors, attributes: attributes, kind: .boundary)
        }
        func walk(_ nodes: [ForumComposerNode], ancestors: [ForumComposerNode], attributes: ForumComposerTextAttributes) {
            var itemNumber = 0
            for node in nodes {
                if node.kind == .text {
                    append(document.substring(node.range), range: node.range, node: node, ancestors: ancestors, attributes: attributes, kind: .text)
                } else if node.kind == .emoticon && !parsesEmoticons {
                    append(document.substring(node.range), range: node.range, node: node, ancestors: ancestors, attributes: attributes, kind: .text)
                } else if node.kind == .opaque {
                    var literal = attributes
                    literal.literal = true
                    append(document.substring(node.range), range: node.range, node: node, ancestors: ancestors, attributes: literal, kind: .text)
                } else if node.tag == .item {
                    itemNumber += 1
                    boundary(node, at: node.range.location, ancestors: ancestors, attributes: attributes)
                    let list = ancestors.last { $0.tag == .list }
                    let marker = Self.listMarker(type: list?.parameter ?? "", number: itemNumber)
                    append("\u{FFFC}", range: node.range, node: node, ancestors: ancestors, attributes: attributes, kind: .listMarker(marker))
                } else if node.isAtomic {
                    let block = node.tag.map { ![.ruby, .img, .attachimg, .attach, .qq].contains($0) } ?? false
                    if block { boundary(node, at: node.range.location, ancestors: ancestors, attributes: attributes) }
                    append("\u{FFFC}", range: node.range, node: node, ancestors: ancestors, attributes: attributes, kind: .atomic)
                    if block { boundary(node, at: node.range.end, ancestors: ancestors, attributes: attributes) }
                } else {
                    var inherited = attributes
                    inherited.apply(node, document: document)
                    if node.tag?.isParagraph == true { boundary(node, at: node.range.location, ancestors: ancestors, attributes: attributes) }
                    if node.children.isEmpty {
                        append("", range: node.contentRange, node: node, ancestors: ancestors + [node], attributes: inherited, kind: .text)
                    } else { walk(node.children, ancestors: ancestors + [node], attributes: inherited) }
                    if node.tag?.isParagraph == true { boundary(node, at: node.range.end, ancestors: ancestors, attributes: attributes) }
                }
            }
        }
        walk(document.nodes, ancestors: [], attributes: .init())
        text = result
        self.spans = spans
    }

    public func sourceOffset(forVisibleOffset offset: Int, affinity: ForumComposerSelection.Affinity = .upstream) -> Int {
        let offset = min(max(0, offset), text.utf16.count)
        let candidates = spans.filter { $0.range.location <= offset && $0.range.end >= offset && $0.kind != .boundary }
        let span = affinity == .upstream ? candidates.first : candidates.last
        guard let span else { return spans.last?.sourceRange.end ?? 0 }
        if span.isAtomic { return offset > span.range.location ? span.sourceRange.end : span.sourceRange.location }
        return span.sourceRange.location + min(offset - span.range.location, span.sourceRange.length)
    }

    public func sourceRange(forVisibleRange range: ForumComposerRange) -> ForumComposerRange {
        let start = sourceOffset(forVisibleOffset: range.location, affinity: range.length == 0 ? .upstream : .downstream)
        let end = sourceOffset(forVisibleOffset: range.end, affinity: .upstream)
        return .init(location: start, length: max(0, end - start))
    }

    public func visibleOffset(forSourceOffset offset: Int, affinity: ForumComposerSelection.Affinity = .upstream) -> Int {
        for span in spans where span.sourceRange.location <= offset && span.sourceRange.end >= offset {
            if span.isAtomic { return offset == span.sourceRange.location || affinity == .downstream && offset < span.sourceRange.end ? span.range.location : span.range.end }
            return span.range.location + min(max(0, offset - span.sourceRange.location), span.range.length)
        }
        return spans.first(where: { $0.sourceRange.location > offset })?.range.location ?? text.utf16.count
    }

    public func visibleRange(for selection: ForumComposerSelection) -> ForumComposerRange {
        let start = visibleOffset(forSourceOffset: selection.sourceRange.location, affinity: selection.affinity)
        let end = visibleOffset(forSourceOffset: selection.sourceRange.end, affinity: selection.affinity)
        return .init(location: start, length: max(0, end - start))
    }

    public func spans(in range: ForumComposerRange) -> [ForumComposerSpan] {
        spans.filter { $0.range.intersection(range) != nil }
    }

    public static func listMarker(type: String, number: Int) -> String {
        if type == "1" { return "\(number)." }
        if type == "a" || type == "A" {
            var value = max(1, number), result = ""
            let base: UInt32 = type == "a" ? 97 : 65
            while value > 0 {
                value -= 1
                result = String(UnicodeScalar(base + UInt32(value % 26))!) + result
                value /= 26
            }
            return result + "."
        }
        return "\u{2022}"
    }
}

extension ForumComposerDocument {
    public func plainText(maskPasswords: Bool = true) -> String {
        if maskPasswords, source.range(of: "[password]", options: .caseInsensitive) != nil {
            let masked = source.replacingOccurrences(of: "(?is)\\[password\\](?:.*?\\[/password\\]|.*$)", with: "[password]", options: .regularExpression)
            if masked != source { return ForumComposerDocument(source: masked).plainText(maskPasswords: false) }
        }
        func walk(_ nodes: [ForumComposerNode]) -> String {
            nodes.map { node in
                if node.kind == .text || node.kind == .opaque { return substring(node.range) }
                if node.tag == .password && maskPasswords { return "[password]" }
                if node.tag == .item { return "\n\u{2022} " }
                if node.tag == .hr || node.tag == .page { return "\n" }
                if node.kind == .emoticon { return substring(node.range) }
                return walk(node.children)
            }.joined()
        }
        return walk(nodes)
    }
}

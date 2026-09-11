import Foundation

/// Offsets use UTF-16, like TextKit. A range never includes half a surrogate pair.
public struct ForumComposerRange: Equatable, Hashable, Codable, Sendable {
    public var location: Int
    public var length: Int
    public var end: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }

    public init(location: Int, length: Int = 0) {
        self.location = max(0, location)
        self.length = max(0, min(length, Int.max - self.location))
    }

    public init(_ range: NSRange) { self.init(location: range.location, length: range.length) }

    public func contains(_ other: Self) -> Bool { location <= other.location && end >= other.end }

    public func intersection(_ other: Self) -> Self? {
        let start = max(location, other.location)
        let end = min(end, other.end)
        return end > start ? Self(location: start, length: end - start) : nil
    }
}

public struct ForumComposerSelection: Equatable, Codable, Sendable {
    public enum Affinity: String, Codable, Sendable { case upstream, downstream }
    public var sourceRange: ForumComposerRange
    public var affinity: Affinity

    public init(sourceRange: ForumComposerRange = .init(location: 0), affinity: Affinity = .upstream) {
        self.sourceRange = sourceRange
        self.affinity = affinity
    }
}

public enum ForumComposerTag: String, CaseIterable, Codable, Sendable {
    case b, i, u, s, font, size, color, backcolor, sup, sub
    case align, p, indent, float, lineh, list, item = "*", hr, quote, code
    case table, tr, td, ruby, collapse, hide, free
    case url, email, img, attach, attachimg, audio, media, flash, swf
    case password, postbg, page, index, indexEntry = "#", begin, fly, qq, groupid

    public static func named(_ name: String) -> Self? {
        switch name.lowercased() {
        case "strong": .b
        case "em": .i
        case "strike": .s
        case "blockquote": .quote
        default: Self(rawValue: name.lowercased())
        }
    }

    public var isInline: Bool {
        [.b, .i, .u, .s, .font, .size, .color, .backcolor, .sup, .sub, .url, .email].contains(self)
    }

    public var isParagraph: Bool { [.align, .p, .indent, .lineh, .quote, .list].contains(self) }
    public var isSingleton: Bool { [.hr, .page, .item, .indexEntry].contains(self) }
    public var isMainPostOnly: Bool { [.page, .index, .indexEntry, .begin, .groupid].contains(self) }
    public var isMedia: Bool { [.audio, .media, .flash, .swf].contains(self) }
    public var isAtomic: Bool { !isInline && !isParagraph }
    public var isLiteralBody: Bool {
        [.code, .img, .attach, .attachimg, .audio, .media, .flash, .swf, .password, .postbg, .begin, .qq].contains(self)
    }
    public var isFormatting: Bool {
        isInline && self != .url && self != .email || [.align, .p, .indent, .lineh].contains(self)
    }
}

public struct ForumComposerNode: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case text, element(ForumComposerTag), opaque, emoticon }
    public var id: String
    public var kind: Kind
    public var range: ForumComposerRange
    public var contentRange: ForumComposerRange
    public var opening: String
    public var closing: String
    public var parameter: String
    public var attributes: ForumComposerAttributes
    public var children: [ForumComposerNode]

    public var tag: ForumComposerTag? { if case let .element(tag) = kind { tag } else { nil } }
    public var isSystem: Bool { tag == .groupid || tag == .i && parameter == "s" }
    public var isAtomic: Bool { isSystem || tag?.isAtomic == true || kind == .emoticon || kind == .opaque }

    public init(id: String = UUID().uuidString, kind: Kind, range: ForumComposerRange,
                contentRange: ForumComposerRange? = nil, opening: String = "", closing: String = "",
                parameter: String = "", attributes: ForumComposerAttributes = .none, children: [Self] = []) {
        self.id = id
        self.kind = kind
        self.range = range
        self.contentRange = contentRange ?? range
        self.opening = opening
        self.closing = closing
        self.parameter = parameter
        self.attributes = attributes
        self.children = children
    }
}

public struct ForumComposerDiagnostic: Equatable, Sendable {
    public enum Reason: String, Sendable { case unknownTag, malformedTag, depthLimit }
    public let range: ForumComposerRange
    public let reason: Reason
}

public struct ForumComposerSourceEdit: Equatable, Sendable {
    public let range: ForumComposerRange
    public let replacement: String
    public var delta: Int { replacement.utf16.count - range.length }

    public init(range: ForumComposerRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    public func map(_ offset: Int, affinity: ForumComposerSelection.Affinity = .upstream) -> Int {
        if offset < range.location { return offset }
        if offset > range.end { return offset + delta }
        if offset == range.location && affinity == .upstream { return offset }
        return range.location + replacement.utf16.count
    }
}

public enum ForumComposerDocumentError: Error, Equatable, Sendable {
    case invalidRange, overlappingEdits, missingNode, invalidParameter, protectedNode, invalidTable
}

/// Source is authoritative. Native previews and persistence never serialize TextKit attributes.
public struct ForumComposerDocument: Equatable, Sendable {
    public private(set) var source: String
    private var sourceUTF16: [UInt16]
    public private(set) var nodes: [ForumComposerNode]
    public private(set) var diagnostics: [ForumComposerDiagnostic]
    public private(set) var revision: UInt64 = 0

    public init(source: String = "") {
        self.source = source
        sourceUTF16 = Array(source.utf16)
        let parsed = ForumComposerDocumentParser.parse(source)
        nodes = parsed.nodes
        diagnostics = parsed.diagnostics
    }

    public func substring(_ range: ForumComposerRange) -> String {
        guard range.end <= sourceUTF16.count else { return "" }
        return String(decoding: sourceUTF16[range.location..<range.end], as: UTF16.self)
    }

    public func node(id: String) -> ForumComposerNode? {
        func find(_ nodes: [ForumComposerNode]) -> ForumComposerNode? {
            for node in nodes {
                if node.id == id { return node }
                if let result = find(node.children) { return result }
            }
            return nil
        }
        return find(nodes)
    }

    public func ancestors(at offset: Int) -> [ForumComposerNode] {
        func find(_ nodes: [ForumComposerNode]) -> [ForumComposerNode] {
            for node in nodes where node.contentRange.location <= offset && node.contentRange.end >= offset {
                guard node.tag != nil, !node.isAtomic else { continue }
                return [node] + find(node.children)
            }
            return []
        }
        return find(nodes)
    }

    @discardableResult
    public mutating func replaceSource(in range: ForumComposerRange, with text: String) throws -> [ForumComposerSourceEdit] {
        let edit = ForumComposerSourceEdit(range: range, replacement: text)
        try applySourceEdits([edit])
        return [edit]
    }

    public mutating func applySourceEdits(_ edits: [ForumComposerSourceEdit]) throws {
        let edits = edits.sorted { $0.range.location < $1.range.location }
        guard !edits.isEmpty else { return }
        for (index, edit) in edits.enumerated() {
            guard edit.range.end <= sourceUTF16.count, validBoundary(edit.range.location),
                  validBoundary(edit.range.end) else { throw ForumComposerDocumentError.invalidRange }
            if index > 0, edits[index - 1].range.end > edit.range.location { throw ForumComposerDocumentError.overlappingEdits }
        }
        if edits.allSatisfy({ substring($0.range) == $0.replacement }) { return }
        var changedUTF16 = sourceUTF16
        for edit in edits.reversed() { changedUTF16.replaceSubrange(edit.range.location..<edit.range.end, with: edit.replacement.utf16) }
        let changed = String(decoding: changedUTF16, as: UTF16.self)

        if edits.count == 1, let edit = edits.first, let leafID = spliceLeaf(edit, in: nodes) {
            nodes = nodes.map { splice($0, edit: edit, leafID: leafID) }
            diagnostics = diagnostics.map { diagnostic in
                .init(range: shifted(diagnostic.range, by: edit), reason: diagnostic.reason)
            }
        } else {
            let parsed = ForumComposerDocumentParser.parse(changed)
            var identities: [String: String] = [:]
            func record(_ nodes: [ForumComposerNode]) {
                for node in nodes {
                    var offset = node.range.location
                    for edit in edits.reversed() { offset = edit.map(offset, affinity: .downstream) }
                    identities[identityKey(node, offset: offset)] = node.id
                    record(node.children)
                }
            }
            record(nodes)
            func retainingIDs(_ node: ForumComposerNode) -> ForumComposerNode {
                var node = node
                node.id = identities[identityKey(node, offset: node.range.location)] ?? node.id
                node.children = node.children.map(retainingIDs)
                return node
            }
            nodes = parsed.nodes.map(retainingIDs)
            diagnostics = parsed.diagnostics
        }
        source = changed
        sourceUTF16 = changedUTF16
        revision &+= 1
    }

    private func identityKey(_ node: ForumComposerNode, offset: Int) -> String {
        "\(offset):\(node.tag?.rawValue ?? String(describing: node.kind))"
    }

    private func validBoundary(_ offset: Int) -> Bool {
        guard offset > 0, offset < sourceUTF16.count else { return true }
        return !(0xDC00...0xDFFF).contains(sourceUTF16[offset])
    }

    private func spliceLeaf(_ edit: ForumComposerSourceEdit, in nodes: [ForumComposerNode]) -> String? {
        let delimiters = CharacterSet(charactersIn: "[]{}")
        guard edit.replacement.rangeOfCharacter(from: delimiters) == nil,
              substring(edit.range).rangeOfCharacter(from: delimiters) == nil else { return nil }
        for node in nodes where node.range.contains(edit.range) {
            // A delimiter-free leaf cannot become a tag by joining its neighbors.
            if node.kind == .text, substring(node.range).rangeOfCharacter(from: delimiters) == nil { return node.id }
            if let id = spliceLeaf(edit, in: node.children) { return id }
        }
        return nil
    }

    private func shifted(_ range: ForumComposerRange, by edit: ForumComposerSourceEdit) -> ForumComposerRange {
        if range.location >= edit.range.end { return .init(location: range.location + edit.delta, length: range.length) }
        if range.contains(edit.range) { return .init(location: range.location, length: range.length + edit.delta) }
        return range
    }

    private func splice(_ node: ForumComposerNode, edit: ForumComposerSourceEdit, leafID: String) -> ForumComposerNode {
        var node = node
        // At a leaf boundary insertion belongs to the leaf ending there, not
        // to its following sibling. Ancestors expand with that leaf.
        func containsLeaf(_ node: ForumComposerNode) -> Bool { node.id == leafID || node.children.contains(where: containsLeaf) }
        if containsLeaf(node) {
            node.range.length += edit.delta
            node.contentRange.length += edit.delta
            node.children = node.children.map { splice($0, edit: edit, leafID: leafID) }
        } else if node.range.location >= edit.range.end {
            node.range.location += edit.delta
            node.contentRange.location += edit.delta
            node.children = node.children.map { splice($0, edit: edit, leafID: leafID) }
        }
        return node
    }
}

import Foundation

public enum ForumComposerCommand: Sendable {
    case replaceSource(ForumComposerRange, String)
    case replaceVisible(ForumComposerRange, String)
    case typeVisible(ForumComposerRange, String, enabled: [ForumComposerTag: String], disabled: Set<ForumComposerTag>)
    case edit([ForumComposerSourceEdit], selection: ForumComposerSelection)
    case insertMarkup(ForumComposerRange, String)
    case format(ForumComposerRange, tag: ForumComposerTag, parameter: String)
    case removeFormatting(ForumComposerRange)
    case removeLink(ForumComposerRange)
    case updateNode(id: String, parameter: String, body: String)
    case replaceNode(id: String, markup: String)
    case unwrapNode(id: String)
}

public struct ForumComposerTransaction: Sendable {
    public let edits: [ForumComposerSourceEdit]
    public let selection: ForumComposerSelection
}

extension ForumComposerDocument {
    @discardableResult
    public mutating func apply(_ command: ForumComposerCommand, parsesEmoticons: Bool = true) throws -> ForumComposerTransaction {
        let projection = ForumComposerProjection(document: self, parsesEmoticons: parsesEmoticons)
        var edits: [ForumComposerSourceEdit] = []
        var selection = ForumComposerSelection()
        switch command {
        case let .edit(changes, finalSelection):
            edits = changes
            selection = finalSelection
        case let .typeVisible(range, text, enabled, disabled):
            let sourceRange = projection.sourceRange(forVisibleRange: range)
            let stack = ancestors(at: sourceRange.location)
            let affected = stack.firstIndex { $0.tag.map(disabled.contains) == true }
            let split = affected.map { Array(stack[$0...]) } ?? []
            let retained = split.filter { $0.tag.map(disabled.contains) != true }
            let prefix = split.reversed().map(\.closing).joined() + retained.map(\.opening).joined()
            let suffix = retained.reversed().map(\.closing).joined() + split.map(\.opening).joined()
            var replacement = text
            for tag in enabled.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                if !stack.contains(where: { $0.tag == tag && $0.parameter == enabled[tag] }) {
                    replacement = try ForumComposerSyntax.markup(tag: tag, parameter: enabled[tag] ?? "", body: replacement)
                }
            }
            edits = [replacementEdit(in: range, text: prefix + replacement + suffix, projection: projection)]
            selection.sourceRange = .init(location: sourceRange.location + prefix.utf16.count + replacement.utf16.count)
        case let .replaceSource(range, text):
            edits = [.init(range: range, replacement: text)]
            selection.sourceRange = .init(location: range.location + text.utf16.count)
        case let .replaceVisible(range, text), let .insertMarkup(range, text):
            let edit = replacementEdit(in: range, text: text, projection: projection)
            edits = [edit]
            selection.sourceRange = .init(location: edit.range.location + text.utf16.count)
        case let .format(range, tag, parameter):
            guard !tag.isMainPostOnly, tag.isInline || tag.isParagraph else { throw ForumComposerDocumentError.invalidParameter }
            _ = try ForumComposerSyntax.markup(tag: tag, parameter: parameter)
            var visible = range
            if tag.isParagraph {
                let paragraph = (projection.text as NSString).paragraphRange(for: range.nsRange)
                visible = .init(paragraph)
            }
            let spans = projection.spans(in: visible).filter { $0.kind != .boundary }
            let removing = !spans.isEmpty && spans.allSatisfy { $0.ancestors.contains { $0.tag == tag && $0.parameter == parameter } }
            if removing { edits = tag == .list ? removingListItems(in: visible, projection: projection) : removingTags([tag], in: visible, projection: projection) }
            else if tag.isParagraph {
                let sourceRange = balancedSourceRange(for: visible, projection: projection)
                var body = substring(sourceRange)
                if tag == .list, !body.contains("[*]") { body = "[*]" + body.replacingOccurrences(of: "\n", with: "\n[*]") }
                edits = [.init(range: sourceRange, replacement: try ForumComposerSyntax.markup(tag: tag, parameter: parameter, body: body))]
            } else {
                edits = spans.compactMap { span in
                    guard let selected = span.range.intersection(visible) else { return nil }
                    let sourceRange = span.isAtomic ? span.sourceRange : ForumComposerRange(location: span.sourceRange.location + selected.location - span.range.location, length: selected.length)
                    let body = substring(sourceRange)
                    let replacement = (try? ForumComposerSyntax.markup(tag: tag, parameter: parameter, body: body)) ?? body
                    return .init(range: sourceRange, replacement: replacement)
                }
            }
            selection = mappedSelection(projection.sourceRange(forVisibleRange: visible), through: edits)
        case let .removeFormatting(range):
            edits = removingTags(Set(ForumComposerTag.allCases.filter(\.isFormatting)), in: range, projection: projection)
            selection = mappedSelection(projection.sourceRange(forVisibleRange: range), through: edits)
        case let .removeLink(range):
            edits = removingTags([.url, .email], in: range, projection: projection)
            selection = mappedSelection(projection.sourceRange(forVisibleRange: range), through: edits)
        case let .updateNode(id, parameter, body):
            guard let node = node(id: id), let tag = node.tag else { throw ForumComposerDocumentError.missingNode }
            guard !node.isSystem else { throw ForumComposerDocumentError.protectedNode }
            let markup = try ForumComposerSyntax.markup(tag: tag, parameter: parameter, body: body)
            // Preserve original delimiters if only a block's content changed.
            let replacement = parameter == node.parameter && !tag.isSingleton ? node.opening + body + node.closing : markup
            edits = [.init(range: node.range, replacement: replacement)]
            selection.sourceRange = .init(location: node.range.location + replacement.utf16.count)
        case let .replaceNode(id, markup):
            guard let node = node(id: id) else { throw ForumComposerDocumentError.missingNode }
            guard !node.isSystem else { throw ForumComposerDocumentError.protectedNode }
            edits = [.init(range: node.range, replacement: markup)]
            selection.sourceRange = .init(location: node.range.location + markup.utf16.count)
        case let .unwrapNode(id):
            guard let node = node(id: id) else { throw ForumComposerDocumentError.missingNode }
            guard !node.isSystem else { throw ForumComposerDocumentError.protectedNode }
            edits = [.init(range: node.range, replacement: substring(node.contentRange))]
            selection.sourceRange = .init(location: node.range.location, length: node.contentRange.length)
        }
        try applySourceEdits(edits)
        return .init(edits: edits, selection: selection)
    }

    public func fragment(in visibleRange: ForumComposerRange, parsesEmoticons: Bool = true) -> String {
        let projection = ForumComposerProjection(document: self, parsesEmoticons: parsesEmoticons)
        return projection.spans(in: visibleRange).map { span in
            guard let selected = span.range.intersection(visibleRange), span.kind != .boundary else { return "\n" }
            let range = span.isAtomic ? span.sourceRange : ForumComposerRange(location: span.sourceRange.location + selected.location - span.range.location, length: selected.length)
            return span.ancestors.map(\.opening).joined() + substring(range) + span.ancestors.reversed().map(\.closing).joined()
        }.joined()
    }

    private func replacementEdit(in range: ForumComposerRange, text: String, projection: ForumComposerProjection) -> ForumComposerSourceEdit {
        let sourceRange = projection.sourceRange(forVisibleRange: range)
        let left = projection.spans.first { $0.range.location <= range.location && $0.range.end > range.location && $0.kind != .boundary }?.ancestors
            ?? ancestors(at: sourceRange.location)
        let right = projection.spans.last { $0.range.location < range.end && $0.range.end >= range.end && $0.kind != .boundary }?.ancestors
            ?? ancestors(at: sourceRange.end)
        let common = zip(left, right).prefix { $0.id == $1.id }.count
        // Balance differently styled edges without serializing either unselected side.
        let repair = range.length == 0 ? "" : left.dropFirst(common).reversed().map(\.closing).joined() + right.dropFirst(common).map(\.opening).joined()
        return .init(range: sourceRange, replacement: text + repair)
    }

    private func balancedSourceRange(for visible: ForumComposerRange, projection: ForumComposerProjection) -> ForumComposerRange {
        var range = projection.sourceRange(forVisibleRange: visible)
        for span in projection.spans(in: visible) {
            for node in span.ancestors {
                let start = projection.visibleOffset(forSourceOffset: node.contentRange.location, affinity: .downstream)
                let end = projection.visibleOffset(forSourceOffset: node.contentRange.end)
                if visible.location <= start && visible.end >= end {
                    let lower = min(range.location, node.range.location), upper = max(range.end, node.range.end)
                    range = .init(location: lower, length: upper - lower)
                }
            }
        }
        return range
    }

    private func removingTags(_ tags: Set<ForumComposerTag>, in visible: ForumComposerRange, projection: ForumComposerProjection) -> [ForumComposerSourceEdit] {
        let spans = projection.spans(in: visible).filter { $0.kind != .boundary }
        var wholeNodes: [String: ForumComposerNode] = [:]
        for span in spans {
            for node in span.ancestors where node.tag.map(tags.contains) == true && !node.isSystem {
                let start = projection.visibleOffset(forSourceOffset: node.contentRange.location, affinity: .downstream)
                let end = projection.visibleOffset(forSourceOffset: node.contentRange.end)
                if visible.location <= start && visible.end >= end { wholeNodes[node.id] = node }
            }
        }
        var edits = wholeNodes.values.flatMap { node in
            [ForumComposerSourceEdit(range: .init(location: node.range.location, length: node.opening.utf16.count), replacement: ""),
             ForumComposerSourceEdit(range: .init(location: node.contentRange.end, length: node.closing.utf16.count), replacement: "")]
        }
        for span in spans {
            guard let selected = span.range.intersection(visible) else { continue }
            let ancestors = span.ancestors.filter { wholeNodes[$0.id] == nil }
            guard let index = ancestors.firstIndex(where: { $0.tag.map(tags.contains) == true && !$0.isSystem }) else { continue }
            let stack = Array(ancestors[index...])
            let retained = stack.filter { $0.tag.map(tags.contains) != true || $0.isSystem }
            let before = stack.reversed().map(\.closing).joined() + retained.map(\.opening).joined()
            let after = retained.reversed().map(\.closing).joined() + stack.map(\.opening).joined()
            let range = span.isAtomic ? span.sourceRange : ForumComposerRange(location: span.sourceRange.location + selected.location - span.range.location, length: selected.length)
            edits.append(.init(range: range, replacement: before + substring(range) + after))
        }
        return edits.sorted { $0.range.location < $1.range.location }
    }

    private func mappedSelection(_ range: ForumComposerRange, through edits: [ForumComposerSourceEdit]) -> ForumComposerSelection {
        var start = range.location, end = range.end
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            start = edit.map(start)
            end = edit.map(end, affinity: .downstream)
        }
        return .init(sourceRange: .init(location: start, length: max(0, end - start)))
    }
}

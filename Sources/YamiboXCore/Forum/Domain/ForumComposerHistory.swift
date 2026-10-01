import Foundation

public struct ForumComposerHistory: Sendable {
    private struct Step: Sendable {
        var forward: [ForumComposerSourceEdit]
        var inverse: [ForumComposerSourceEdit]
    }
    private struct Entry: Sendable {
        var steps: [Step]
        /// One source replacement for applying the group, while `steps` keep
        /// the original edit order used to map bookmarks and selections.
        var application: Step
        /// Only groups that splice the same stable text leaf throughout may
        /// apply the composed replacement without changing identity semantics.
        var splicedNodeID: String?
        var before: ForumComposerSelection
        var after: ForumComposerSelection
        var typing: Bool
        var date: Date
    }
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public init() {}

    @discardableResult
    public mutating func perform(_ command: ForumComposerCommand, in document: inout ForumComposerDocument,
                                 selection: ForumComposerSelection, typing: Bool = false, date: Date = .now, parsesEmoticons: Bool = true,
                                 projection: ForumComposerProjection? = nil) throws -> ForumComposerTransaction {
        let before = document
        let transaction = try document.apply(command, parsesEmoticons: parsesEmoticons, projection: projection)
        guard document.source != before.source else { return transaction }
        var delta = 0
        let inverse = transaction.edits.sorted { $0.range.location < $1.range.location }.map { edit in
            let inverse = ForumComposerSourceEdit(range: .init(location: edit.range.location + delta, length: edit.replacement.utf16.count), replacement: before.substring(edit.range))
            delta += edit.delta
            return inverse
        }
        let step = Step(forward: transaction.edits, inverse: inverse)
        let splicedNodeID = document.lastTextSplice.flatMap { splice in
            splice.sourceBefore == before.source && transaction.edits == [splice.edit] ? splice.nodeID : nil
        }
        if typing, let index = undoEntries.indices.last, undoEntries[index].typing,
           undoEntries[index].after == selection, date.timeIntervalSince(undoEntries[index].date) < 1 {
            undoEntries[index].application = Self.composing(undoEntries[index].application, with: step, before: before, after: document)
            if undoEntries[index].splicedNodeID != splicedNodeID { undoEntries[index].splicedNodeID = nil }
            undoEntries[index].steps.append(step)
            undoEntries[index].after = transaction.selection
            undoEntries[index].date = date
        } else {
            undoEntries.append(.init(steps: [step], application: Self.application(for: step, before: before, after: document),
                                     splicedNodeID: splicedNodeID,
                                     before: selection, after: transaction.selection, typing: typing, date: date))
        }
        redoEntries.removeAll()
        if undoEntries.count > 200 { undoEntries.removeFirst(undoEntries.count - 200) }
        return transaction
    }

    public mutating func undo(in document: inout ForumComposerDocument) throws -> ForumComposerTransaction? {
        guard let entry = undoEntries.last else { return nil }
        var copy = document
        var edits: [ForumComposerSourceEdit] = []
        for step in entry.steps.reversed() { edits += step.inverse.sorted { $0.range.location > $1.range.location } }
        if let nodeID = entry.splicedNodeID, let edit = entry.application.inverse.first,
           copy.canSpliceSingle(edit, nodeID: nodeID) {
            try copy.applySourceEdits(entry.application.inverse)
        } else {
            for step in entry.steps.reversed() { try copy.applySourceEdits(step.inverse) }
        }
        document = copy
        undoEntries.removeLast()
        redoEntries.append(entry)
        return .init(edits: edits, selection: entry.before)
    }

    public mutating func redo(in document: inout ForumComposerDocument) throws -> ForumComposerTransaction? {
        guard let entry = redoEntries.last else { return nil }
        var copy = document
        var edits: [ForumComposerSourceEdit] = []
        for step in entry.steps { edits += step.forward.sorted { $0.range.location > $1.range.location } }
        if let nodeID = entry.splicedNodeID, let edit = entry.application.forward.first,
           copy.canSpliceSingle(edit, nodeID: nodeID) {
            try copy.applySourceEdits(entry.application.forward)
        } else {
            for step in entry.steps { try copy.applySourceEdits(step.forward) }
        }
        document = copy
        redoEntries.removeLast()
        undoEntries.append(entry)
        return .init(edits: edits, selection: entry.after)
    }

    public mutating func breakTypingGroup() {
        if !undoEntries.isEmpty { undoEntries[undoEntries.count - 1].typing = false }
    }

    private static func application(for step: Step, before: ForumComposerDocument, after: ForumComposerDocument) -> Step {
        guard let lower = step.forward.map(\.range.location).min(), let upper = step.forward.map(\.range.end).max() else { return step }
        let range = ForumComposerRange(location: lower, length: upper - lower)
        let changedRange = ForumComposerRange(location: lower, length: range.length + step.forward.reduce(0) { $0 + $1.delta })
        return Step(forward: [.init(range: range, replacement: after.substring(changedRange))],
                    inverse: [.init(range: changedRange, replacement: before.substring(range))])
    }

    private static func composing(_ previous: Step, with step: Step, before: ForumComposerDocument, after: ForumComposerDocument) -> Step {
        guard let original = previous.forward.first, let current = previous.inverse.first,
              let lower = step.forward.map(\.range.location).min(), let upper = step.forward.map(\.range.end).max() else { return previous }
        let start = min(current.range.location, lower), end = max(current.range.end, upper)
        let left = ForumComposerRange(location: start, length: current.range.location - start)
        let right = ForumComposerRange(location: current.range.end, length: end - current.range.end)
        let originalRange = ForumComposerRange(location: original.range.location - left.length,
                                               length: original.range.length + left.length + right.length)
        let changedRange = ForumComposerRange(location: start, length: end - start + step.forward.reduce(0) { $0 + $1.delta })
        return Step(forward: [.init(range: originalRange, replacement: after.substring(changedRange))],
                    inverse: [.init(range: changedRange, replacement: before.substring(left) + current.replacement + before.substring(right))])
    }
}

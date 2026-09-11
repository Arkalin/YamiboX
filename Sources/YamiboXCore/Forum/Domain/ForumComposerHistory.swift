import Foundation

public struct ForumComposerHistory: Sendable {
    private struct Step: Sendable {
        var forward: [ForumComposerSourceEdit]
        var inverse: [ForumComposerSourceEdit]
    }
    private struct Entry: Sendable {
        var steps: [Step]
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
                                 selection: ForumComposerSelection, typing: Bool = false, date: Date = .now, parsesEmoticons: Bool = true) throws -> ForumComposerTransaction {
        let before = document
        let transaction = try document.apply(command, parsesEmoticons: parsesEmoticons)
        guard document.source != before.source else { return transaction }
        var delta = 0
        let inverse = transaction.edits.sorted { $0.range.location < $1.range.location }.map { edit in
            let inverse = ForumComposerSourceEdit(range: .init(location: edit.range.location + delta, length: edit.replacement.utf16.count), replacement: before.substring(edit.range))
            delta += edit.delta
            return inverse
        }
        let step = Step(forward: transaction.edits, inverse: inverse)
        if typing, var last = undoEntries.last, last.typing, last.after == selection, date.timeIntervalSince(last.date) < 1 {
            last.steps.append(step)
            last.after = transaction.selection
            last.date = date
            undoEntries[undoEntries.count - 1] = last
        } else {
            undoEntries.append(.init(steps: [step], before: selection, after: transaction.selection, typing: typing, date: date))
        }
        redoEntries.removeAll()
        if undoEntries.count > 200 { undoEntries.removeFirst(undoEntries.count - 200) }
        return transaction
    }

    public mutating func undo(in document: inout ForumComposerDocument) throws -> ForumComposerTransaction? {
        guard let entry = undoEntries.last else { return nil }
        var copy = document
        var edits: [ForumComposerSourceEdit] = []
        for step in entry.steps.reversed() { try copy.applySourceEdits(step.inverse); edits += step.inverse.sorted { $0.range.location > $1.range.location } }
        document = copy
        undoEntries.removeLast()
        redoEntries.append(entry)
        return .init(edits: edits, selection: entry.before)
    }

    public mutating func redo(in document: inout ForumComposerDocument) throws -> ForumComposerTransaction? {
        guard let entry = redoEntries.last else { return nil }
        var copy = document
        var edits: [ForumComposerSourceEdit] = []
        for step in entry.steps { try copy.applySourceEdits(step.forward); edits += step.forward.sorted { $0.range.location > $1.range.location } }
        document = copy
        redoEntries.removeLast()
        undoEntries.append(entry)
        return .init(edits: edits, selection: entry.after)
    }

    public mutating func breakTypingGroup() {
        if !undoEntries.isEmpty { undoEntries[undoEntries.count - 1].typing = false }
    }
}

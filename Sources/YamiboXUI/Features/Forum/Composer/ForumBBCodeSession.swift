import Observation
import SwiftUI
import UIKit
import YamiboXCore

struct ForumComposerNodeEditRequest: Identifiable {
    let id = UUID()
    let nodeID: String?
    let tag: ForumComposerTag
    let parameter: String
    let body: String
    let originalSource: String?
    let anchorID: UUID
}

@MainActor
@Observable
final class ForumBBCodeSession {
    enum MarkState { case off, on, mixed }
    var sourceMode = false
    var isFullScreen = false
    var isComposing = false
    var nodeRequest: ForumComposerNodeEditRequest?
    var errorMessage: String?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var marks: [ForumComposerTag: MarkState] = [:]
    private(set) var changeID: UInt64 = 0
    @ObservationIgnored private(set) var document = ForumComposerDocument()
    @ObservationIgnored private(set) var projection = ForumComposerProjection(document: .init())
    @ObservationIgnored var context = ForumComposerContext()
    @ObservationIgnored var parsesBBCode = true
    @ObservationIgnored var parsesEmoticons = true
    @ObservationIgnored var theme: ForumTheme = .classic
    @ObservationIgnored var baseFontSize: CGFloat = 17
    @ObservationIgnored var imagePipeline: YamiboUIImagePipeline?
    @ObservationIgnored var refererURL = YamiboDomain.baseURL
    @ObservationIgnored weak var view: ForumBBCodeTextView?
    @ObservationIgnored var onSourceChange: ((String) -> Void)?
    @ObservationIgnored var onStateChange: ((Bool, ForumComposerSelection) -> Void)?
    @ObservationIgnored var onPasteImage: ((Data) -> Void)?
    @ObservationIgnored var imagePasteHandlerID: UUID?
    @ObservationIgnored var onURLTap: ((URL) -> Void)?
    @ObservationIgnored var localImages: [String: UIImage] = [:] {
        didSet { for attachment in attachmentCache.values { attachment.refreshLocalImages() } }
    }
    @ObservationIgnored private var history = ForumComposerHistory()
    @ObservationIgnored private(set) var selection = ForumComposerSelection()
    @ObservationIgnored private var anchors: [UUID: ForumComposerSelection] = [:]
    @ObservationIgnored private var typingMarks: [ForumComposerTag: String?] = [:]
    @ObservationIgnored private var attachmentCache: [String: ForumBBCodeAttachment] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var activeNodeAnchor: UUID?
    @ObservationIgnored var isRendering = false

    var source: String { document.source }
    var isVisual: Bool { !sourceMode && parsesBBCode }

    func load(_ source: String, force: Bool = false) {
        guard view?.markedTextRange == nil else { return }
        let changed = !loaded || source != document.source
        if changed {
            document = ForumComposerDocument(source: source)
            history = ForumComposerHistory()
            anchors = [:]
            typingMarks = [:]
            selection.sourceRange = .init(location: min(selection.sourceRange.location, source.utf16.count))
            loaded = true
        }
        if changed || force {
            projection = ForumComposerProjection(document: document, parsesBBCode: isVisual, parsesEmoticons: parsesEmoticons)
            render(force: true)
            DispatchQueue.main.async { [weak self] in self?.publish() }
        }
    }

    func attach(_ view: ForumBBCodeTextView) { self.view = view; view.session = self }

    func commitComposition(resign: Bool = false) {
        guard let view else { return }
        view.unmarkText()
        isComposing = false
        view.delegate?.textViewDidChange?(view)
        captureSelection()
        if resign { view.resignFirstResponder() }
    }

    func captureSelection(userInitiated: Bool = false) {
        guard let view, !isRendering, view.markedTextRange == nil else { return }
        // UIKit can notify selection changes before the corresponding text edit.
        guard !userInitiated || (view.text ?? "") == projection.text else { return }
        let next = ForumComposerSelection(sourceRange: isVisual ? projection.sourceRange(forVisibleRange: .init(view.selectedRange)) : .init(view.selectedRange))
        if userInitiated, next != selection { typingMarks = [:]; history.breakTypingGroup() }
        selection = next
        updateMarks()
        onStateChange?(sourceMode, selection)
    }

    func restoreState(sourceMode: Bool, selection: ForumComposerSelection) {
        commitComposition()
        self.sourceMode = sourceMode
        self.selection = selection
        projection = ForumComposerProjection(document: document, parsesBBCode: isVisual, parsesEmoticons: parsesEmoticons)
        render(force: true)
        onStateChange?(sourceMode, selection)
    }

    func setSourceMode(_ sourceMode: Bool) {
        guard self.sourceMode != sourceMode else { return }
        commitComposition(resign: true)
        history.breakTypingGroup()
        typingMarks = [:]
        self.sourceMode = sourceMode
        projection = ForumComposerProjection(document: document, parsesBBCode: isVisual, parsesEmoticons: parsesEmoticons)
        render(force: true)
        onStateChange?(sourceMode, selection)
    }

    func textChanged(from oldText: String, to text: String, visibleSelection: NSRange) {
        guard !isRendering, oldText != text else { return }
        let difference = Self.difference(from: oldText, to: text)
        let enabled = typingMarks.compactMapValues { $0 }
        let disabled = Set(typingMarks.filter { $0.value == nil }.keys)
        let command: ForumComposerCommand = isVisual
            ? .typeVisible(difference.range, difference.replacement, enabled: enabled, disabled: disabled)
            : .replaceSource(difference.range, difference.replacement)
        perform(command, typing: true, render: false)
        if projection.text == text {
            selection.sourceRange = isVisual ? projection.sourceRange(forVisibleRange: .init(visibleSelection)) : .init(visibleSelection)
            updateTypingAttributes()
        } else { render(force: false) }
        publish()
    }

    @discardableResult
    func perform(_ command: ForumComposerCommand, typing: Bool = false, render shouldRender: Bool = true) -> Bool {
        do {
            let transaction = try history.perform(command, in: &document, selection: selection, typing: typing, parsesEmoticons: parsesEmoticons)
            mapAnchors(transaction.edits.sorted { $0.range.location > $1.range.location })
            selection = transaction.selection
            projection = ForumComposerProjection(document: document, parsesBBCode: isVisual, parsesEmoticons: parsesEmoticons)
            if shouldRender { render(force: false) }
            publish()
            return true
        } catch { errorMessage = L10n.string("forum.composer.invalid_edit"); return false }
    }

    func handleListInput(range: NSRange, text: String) -> Bool {
        let command: ForumComposerCommand?
        if text == "\n", range.length == 0 { command = document.listInput(at: range.location, parsesEmoticons: parsesEmoticons) }
        else if text.isEmpty, range.length == 1 { command = document.listInput(at: range.location + 1, backspace: true, parsesEmoticons: parsesEmoticons) }
        else { return false }
        guard let command else { return false }
        perform(command)
        return true
    }

    func indentList(increase: Bool) {
        commitComposition()
        guard let view, let command = document.listIndent(at: view.selectedRange.location, increase: increase, parsesEmoticons: parsesEmoticons) else { return }
        perform(command)
    }

    func format(_ tag: ForumComposerTag, parameter: String = "") {
        guard context.capability(for: tag) != .denied else { return }
        commitComposition()
        guard let view else { return }
        if isVisual {
            if view.selectedRange.length == 0 && tag.isInline {
                if tag == .sup { typingMarks[.sub] = .some(nil) }
                if tag == .sub { typingMarks[.sup] = .some(nil) }
                let active = marks[tag] == .on
                if active {
                    // A collapsed removal splits inherited formatting only
                    // when text is actually entered, so a toggle alone is not an edit.
                    typingMarks[tag] = .some(nil)
                } else { typingMarks[tag] = .some(parameter) }
                marks[tag] = active ? .off : .on
                updateTypingAttributes()
                view.becomeFirstResponder()
                return
            }
            perform(.format(.init(view.selectedRange), tag: tag, parameter: parameter))
        } else {
            let range = selection.sourceRange
            if let markup = try? ForumComposerSyntax.markup(tag: tag, parameter: parameter, body: document.substring(range)) {
                perform(.replaceSource(range, markup))
            }
        }
        view.becomeFirstResponder()
    }

    func removeFormatting(linksOnly: Bool = false) {
        commitComposition()
        guard isVisual, let view else { return }
        if view.selectedRange.length == 0 {
            for tag in ForumComposerTag.allCases where linksOnly ? [.url, .email].contains(tag) : tag.isFormatting { typingMarks[tag] = .some(nil) }
            updateTypingAttributes()
        } else { perform(linksOnly ? .removeLink(.init(view.selectedRange)) : .removeFormatting(.init(view.selectedRange))) }
    }

    func insertMarkup(_ markup: String, at anchorID: UUID? = nil) -> Bool {
        commitComposition()
        if let anchorID {
            guard let anchor = anchors.removeValue(forKey: anchorID) else { return false }
            selection = anchor
        }
        let inserted = isVisual ? perform(.insertMarkup(projection.visibleRange(for: selection), markup)) : perform(.replaceSource(selection.sourceRange, markup))
        view?.becomeFirstResponder()
        return inserted
    }

    func bookmark() -> UUID {
        commitComposition()
        let id = UUID()
        anchors[id] = selection
        return id
    }

    func bookmark(selection: ForumComposerSelection) -> UUID {
        let id = UUID(); anchors[id] = selection; return id
    }
    func bookmarkedSelection(_ id: UUID) -> ForumComposerSelection? { anchors[id] }
    func removeBookmark(_ id: UUID) { anchors[id] = nil }

    func editNode(_ id: String) {
        commitComposition(resign: true)
        guard let node = document.node(id: id), let tag = node.tag, !node.isSystem else { return }
        nodeRequest = .init(nodeID: id, tag: tag, parameter: node.parameter, body: document.substring(node.contentRange),
                            originalSource: document.substring(node.range), anchorID: bookmark())
        activeNodeAnchor = nodeRequest?.anchorID
    }

    func insertNode(_ tag: ForumComposerTag) {
        guard context.capability(for: tag) != .denied else { return }
        commitComposition(resign: true)
        if tag == .password || tag == .postbg {
            func first(_ nodes: [ForumComposerNode]) -> ForumComposerNode? {
                for node in nodes {
                    if node.tag == tag { return node }
                    if let found = first(node.children) { return found }
                }
                return nil
            }
            if let existing = first(document.nodes) { editNode(existing.id); return }
            nodeRequest = .init(nodeID: nil, tag: tag, parameter: "", body: "", originalSource: nil,
                                anchorID: bookmark(selection: .init(sourceRange: .init(location: 0))))
            activeNodeAnchor = nodeRequest?.anchorID
            return
        }
        if let existing = document.ancestors(at: selection.sourceRange.location).last(where: { $0.tag == tag }), tag.isInline || tag.isParagraph {
            editNode(existing.id)
            return
        }
        if tag.isParagraph, isVisual, let view {
            selection.sourceRange = projection.sourceRange(forVisibleRange: .init((projection.text as NSString).paragraphRange(for: view.selectedRange)))
        }
        let visible = projection.visibleRange(for: selection)
        let body = isVisual ? document.fragment(in: visible, parsesEmoticons: parsesEmoticons) : document.substring(selection.sourceRange)
        nodeRequest = .init(nodeID: nil, tag: tag, parameter: ForumComposerLabels.defaultParameter(tag), body: body,
                            originalSource: nil, anchorID: bookmark())
        activeNodeAnchor = nodeRequest?.anchorID
    }

    func cancelNodeEditing() {
        if let activeNodeAnchor { removeBookmark(activeNodeAnchor) }
        activeNodeAnchor = nil
        nodeRequest = nil
    }

    func saveNode(_ request: ForumComposerNodeEditRequest, parameter: String, body: String, replacement: String? = nil) -> Bool {
        do {
            let markup = try replacement ?? ForumComposerSyntax.markup(tag: request.tag, parameter: parameter, body: body)
            if request.tag == .postbg, !context.backgrounds.contains(where: { $0.name == body }) { throw ForumComposerDocumentError.invalidParameter }
            if let id = request.nodeID {
                guard let node = document.node(id: id), document.substring(node.range) == request.originalSource else {
                    errorMessage = L10n.string("forum.composer.block_changed")
                    return false
                }
                let saved = replacement != nil ? perform(.replaceNode(id: id, markup: markup)) : perform(.updateNode(id: id, parameter: parameter, body: body))
                guard saved else { return false }
                removeBookmark(request.anchorID)
            } else {
                guard context.capability(for: request.tag) != .denied else { return false }
                if request.tag.isInline, ![.url, .email].contains(request.tag), body.isEmpty,
                   let anchor = anchors[request.anchorID], anchor.sourceRange.length == 0, isVisual {
                    selection = anchor
                    render(force: false)
                    typingMarks[request.tag] = .some(parameter)
                    updateTypingAttributes()
                    updateMarks()
                    removeBookmark(request.anchorID)
                    nodeRequest = nil
                    return true
                }
                let saved: Bool
                if request.tag == .password || request.tag == .postbg {
                    if let anchor = anchors.removeValue(forKey: request.anchorID) { saved = perform(.replaceSource(anchor.sourceRange, markup + "\n")) }
                    else { saved = false }
                } else { saved = insertMarkup(markup, at: request.anchorID) }
                guard saved else {
                    errorMessage = L10n.string("forum.composer.anchor_missing")
                    return false
                }
            }
            nodeRequest = nil
            return true
        } catch { errorMessage = L10n.string("forum.composer.invalid_parameters"); return false }
    }

    func undo() {
        commitComposition()
        do {
            guard let transaction = try history.undo(in: &document) else { return }
            mapAnchors(transaction.edits)
            selection = transaction.selection
            typingMarks = [:]
            projection = .init(document: document, parsesBBCode: isVisual, parsesEmoticons: parsesEmoticons)
            render(force: false)
            publish()
        } catch { errorMessage = L10n.string("forum.composer.invalid_edit") }
    }

    func redo() {
        commitComposition()
        do {
            guard let transaction = try history.redo(in: &document) else { return }
            mapAnchors(transaction.edits)
            selection = transaction.selection
            typingMarks = [:]
            projection = .init(document: document, parsesBBCode: isVisual, parsesEmoticons: parsesEmoticons)
            render(force: false)
            publish()
        } catch { errorMessage = L10n.string("forum.composer.invalid_edit") }
    }

    func render(force: Bool) {
        guard let view, view.markedTextRange == nil else { return }
        isRendering = true
        defer { isRendering = false }
        let attributed = ForumBBCodeTextCodec.attributedText(session: self)
        let difference = Self.difference(from: view.text ?? "", to: attributed.string)
        if force { view.textStorage.setAttributedString(attributed) }
        else {
            view.textStorage.beginEditing()
            if difference.range.length > 0 || !difference.replacement.isEmpty {
                let replacementRange = NSRange(location: difference.range.location, length: difference.replacement.utf16.count)
                view.textStorage.replaceCharacters(in: difference.range.nsRange, with: attributed.attributedSubstring(from: replacementRange))
            }
            // Commands can change attributes without changing visible characters.
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                view.textStorage.setAttributes(attributes, range: range)
            }
            view.textStorage.endEditing()
        }
        let range = isVisual ? projection.visibleRange(for: selection).nsRange : selection.sourceRange.nsRange
        view.selectedRange = NSRange(location: min(range.location, attributed.length), length: min(range.length, max(0, attributed.length - range.location)))
        updateTypingAttributes()
    }

    func attachment(for span: ForumComposerSpan) -> ForumBBCodeAttachment? {
        guard let node = document.node(id: span.nodeID) else { return nil }
        let source = document.substring(node.range)
        if let existing = attachmentCache[node.id], existing.source == source, existing.baseFontSize == baseFontSize { return existing }
        let attachment = ForumBBCodeAttachment(node: node, source: source, span: span, session: self)
        attachmentCache[node.id] = attachment
        return attachment
    }

    func invalidateAttachments() { attachmentCache = [:] }

    func updateTypingAttributes() {
        guard let view else { return }
        if !isVisual { view.typingAttributes = [.font: UIFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular), .foregroundColor: UIColor.label]; return }
        let offset = projection.visibleOffset(forSourceOffset: selection.sourceRange.location)
        var attributes = projection.spans.first { $0.range.location <= offset && $0.range.end >= offset && !$0.isAtomic && $0.kind != .boundary }?.attributes ?? .init()
        for (tag, parameter) in typingMarks.sorted(by: {
            if ($0.value == nil) != ($1.value == nil) { return $0.value == nil }
            return $0.key.rawValue < $1.key.rawValue
        }) {
            let enabled = parameter != nil
            switch tag {
            case .b: attributes.bold = enabled
            case .i: attributes.italic = enabled
            case .u: attributes.underline = enabled
            case .s: attributes.strikethrough = enabled
            case .font: attributes.fontName = parameter
            case .size:
                attributes.relativeSize = nil; attributes.pointSize = nil
                if let parameter, case let .fontSize(relative, points) = ForumComposerAttributes.parse(tag: tag, parameter: parameter) { attributes.relativeSize = relative; attributes.pointSize = points }
            case .color: attributes.foregroundHex = parameter.flatMap(ForumComposerSyntax.normalizedColor)
            case .backcolor: attributes.backgroundHex = parameter.flatMap(ForumComposerSyntax.normalizedColor)
            case .sup: attributes.baseline = enabled ? 1 : 0
            case .sub: attributes.baseline = enabled ? -1 : 0
            case .url, .email: attributes.link = parameter.flatMap { ForumComposerSyntax.safeURL($0, email: tag == .email) }
            default: break
            }
        }
        var typing = ForumBBCodeTextCodec.attributes(attributes, theme: theme, baseFontSize: baseFontSize)
        if attributes.listLevel > 0, view.textStorage.length > 0,
           let paragraph = view.textStorage.attribute(.paragraphStyle, at: min(offset, view.textStorage.length - 1), effectiveRange: nil) {
            typing[.paragraphStyle] = paragraph
        }
        view.typingAttributes = typing
    }

    private func updateMarks() {
        guard let view else { return }
        let range = ForumComposerRange(view.selectedRange)
        let spans = range.length == 0 ? projection.spans.filter { $0.range.location <= range.location && $0.range.end >= range.location && $0.kind != .boundary }.prefix(1).map { $0 } : projection.spans(in: range).filter { $0.kind != .boundary }
        var result: [ForumComposerTag: MarkState] = [:]
        for tag in ForumComposerTag.allCases where tag.isInline || tag.isParagraph {
            let count = spans.filter { $0.ancestors.contains { $0.tag == tag } }.count
            result[tag] = count == 0 ? .off : count == spans.count ? .on : .mixed
        }
        for (tag, parameter) in typingMarks { result[tag] = parameter == nil ? .off : .on }
        marks = result
    }

    private func mapAnchors(_ edits: [ForumComposerSourceEdit]) {
        for edit in edits {
            for (id, anchor) in anchors {
                if edit.range.length > 0 && (edit.range.intersection(anchor.sourceRange) != nil || edit.range.location < anchor.sourceRange.location && edit.range.end > anchor.sourceRange.location) {
                    anchors[id] = nil
                } else {
                    let start = edit.map(anchor.sourceRange.location, affinity: .downstream)
                    let end = edit.map(anchor.sourceRange.end, affinity: .downstream)
                    anchors[id] = .init(sourceRange: .init(location: start, length: max(0, end - start)))
                }
            }
        }
    }

    private func publish() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        changeID &+= 1
        updateMarks()
        onSourceChange?(document.source)
        onStateChange?(sourceMode, selection)
        let live = Set(projection.spans.filter(\.isAtomic).map(\.nodeID))
        attachmentCache = attachmentCache.filter { live.contains($0.key) }
    }

    static func difference(from before: String, to after: String) -> ForumComposerSourceEdit {
        let old = before as NSString, new = after as NSString
        var prefix = 0
        while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix > 0, prefix < old.length, (0xDC00...0xDFFF).contains(old.character(at: prefix)) { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.length - prefix, new.length - prefix), old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) { suffix += 1 }
        if suffix > 0, old.length - suffix > prefix, (0xDC00...0xDFFF).contains(old.character(at: old.length - suffix)) { suffix -= 1 }
        return .init(range: .init(location: prefix, length: old.length - prefix - suffix), replacement: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))
    }
}

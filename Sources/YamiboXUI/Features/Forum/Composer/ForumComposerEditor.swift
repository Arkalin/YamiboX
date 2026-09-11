import SwiftUI
import UIKit
import YamiboXCore

enum ForumComposerMode: String, CaseIterable {
    case visual, code
}

struct ForumComposerEditor: View {
    @Binding var text: String
    let isBlog: Bool
    @Binding var isHTMLSource: Bool
    var editorController: ForumEditorController? = nil
    var composerContext = ForumComposerContext()
    var parsesBBCode = true
    var parsesEmoticons = true
    var onDrafts: (() -> Void)?
    var draftStatus: String?
    @State private var localController = ForumEditorController()
    @State private var showsLinkPrompt = false
    @State private var showsEmoticons = false
    @State private var pendingEmoticon: ForumEmoticon?
    @State private var link = ""
    @State private var mode = ForumComposerMode.visual

    private var controller: ForumEditorController { editorController ?? localController }

    var body: some View {
        if isBlog { blogEditor }
        else {
            ForumBBCodeEditor(text: $text, controller: controller, composerContext: composerContext, parsesBBCode: parsesBBCode,
                              parsesEmoticons: parsesEmoticons, onDrafts: onDrafts, draftStatus: draftStatus)
        }
    }

    private var blogEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ForumTextEditor(text: $text, isHTMLSource: $isHTMLSource, isBlog: isBlog, mode: mode, controller: controller)
                    .frame(height: 280)
                    .accessibilityLabel(L10n.string("forum.native.message"))
                if text.isEmpty {
                    Text(L10n.string("forum.native.message_placeholder"))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    Button {
                        controller.pauseEditing()
                        showsEmoticons = true
                    } label: { Image(systemName: "face.smiling").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("forum.native.emoticons"))
                        .accessibilityIdentifier("native-composer-emoticons")
                        .help(L10n.string("forum.native.emoticons"))
                    formatButton("bold", title: "forum.native.bold", tag: "b")
                    formatButton("italic", title: "forum.native.italic", tag: "i")
                    formatButton("underline", title: "forum.native.underline", tag: "u")
                    formatButton("text.quote", title: "forum.native.quote", tag: isBlog ? "blockquote" : "quote")
                    Button { controller.pauseEditing(); showsLinkPrompt = true } label: { Image(systemName: "link").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("forum.native.insert_link"))
                        .help(L10n.string("forum.native.insert_link"))
                    Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("common.undo"))
                        .help(L10n.string("common.undo"))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 19))
            }
            .scrollIndicators(.hidden)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    characterCount
                    Spacer(minLength: 12)
                    plainTextToggle
                }
                VStack(alignment: .leading, spacing: 4) {
                    characterCount
                    plainTextToggle.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .sheet(isPresented: $showsEmoticons, onDismiss: insertPendingEmoticon) {
            ForumEmoticonPicker { item in
                pendingEmoticon = item
                showsEmoticons = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(L10n.string("forum.native.insert_link"), isPresented: $showsLinkPrompt) {
            TextField("https://", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(L10n.string("common.cancel"), role: .cancel) { controller.cancelPausedEditing() }
            Button(L10n.string("common.confirm")) { insertLink() }
                .disabled(validLink == nil)
        }
    }

    private var characterCount: some View {
        Text(L10n.string("forum.native.character_count", text.count))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var plainTextToggle: some View {
        Toggle(L10n.string("forum.native.plain_text"), isOn: Binding(
            get: { mode == .code },
            set: { changeMode($0 ? .code : .visual) }
        ))
        .toggleStyle(.switch)
        .font(.subheadline)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 44)
        .accessibilityIdentifier("native-composer-plain-text")
    }

    private func formatButton(_ symbol: String, title: String, tag: String) -> some View {
        Button {
            wrap(before: isBlog ? "<\(tag)>" : "[\(tag)]", after: isBlog ? "</\(tag)>" : "[/\(tag)]")
        } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .accessibilityLabel(L10n.string(title))
        .help(L10n.string(title))
    }

    private var validLink: URL? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, !url.absoluteString.contains("]") else { return nil }
        return url
    }

    private func insertLink() {
        guard let url = validLink else { return }
        if isBlog {
            let escaped = ForumPageSession.htmlFromPlainText(url.absoluteString)
            wrap(before: "<a href=\"\(escaped)\">", after: "</a>", placeholder: url.absoluteString)
        } else {
            wrap(before: "[url=\(url.absoluteString)]", after: "[/url]", placeholder: url.absoluteString)
        }
        link = ""
    }

    private func wrap(before: String, after: String, placeholder: String = "") {
        let encodePlainText = isBlog && !isHTMLSource
        controller.wrap(before: before, after: after, placeholder: placeholder, encodeHTML: encodePlainText)
        if isBlog && mode == .code { isHTMLSource = true }
    }

    private func insertPendingEmoticon() {
        guard let item = pendingEmoticon else { controller.cancelPausedEditing(); return }
        pendingEmoticon = nil
        controller.insertEmoticon(item, isBlog: isBlog, encodeHTML: isBlog && !isHTMLSource)
        if isBlog && mode == .code { isHTMLSource = true }
    }

    private func changeMode(_ mode: ForumComposerMode) {
        guard self.mode != mode else { return }
        controller.pauseEditing()
        controller.cancelPausedEditing()
        if mode == .code && isBlog && !isHTMLSource {
            text = ForumComposerMarkup.escapeHTML(text)
            isHTMLSource = true
        }
        self.mode = mode
    }
}

@MainActor
final class ForumEditorRegistry {
    private var controllers: [String: ForumEditorController] = [:]

    func controller(for fieldID: String) -> ForumEditorController {
        if let controller = controllers[fieldID] { return controller }
        let controller = ForumEditorController()
        controllers[fieldID] = controller
        return controller
    }

    func commitEditing() {
        for controller in controllers.values {
            controller.pauseEditing()
            controller.cancelPausedEditing()
        }
    }

    func clear() {
        for controller in controllers.values {
            controller.view?.resignFirstResponder()
            controller.bbcodeSession.onSourceChange = nil
            controller.bbcodeSession.onStateChange = nil
            controller.bbcodeSession.load("", force: true)
            controller.view?.text = ""
        }
        controllers = [:]
    }

    func prepareSubmission(form: ForumForm, button: ForumFormButton, model: ForumPageSession) {
        commitEditing()
        model.prepareSubmission(form: form, button: button)
    }
}

@MainActor
final class ForumEditorController {
    weak var view: UITextView?
    let bbcodeSession = ForumBBCodeSession()
    var usesBBCodeDocument = false
    var hasRestoredDraftState = false
    var richSession: ForumRichEditorSession?
    var isVisual = false
    private var savedSelection: NSRange?

    func pauseEditing() {
        if usesBBCodeDocument { bbcodeSession.commitComposition(resign: true); return }
        guard let view else { return }
        // Commit IME composition before bookmarking the final UTF-16 cursor.
        view.unmarkText()
        view.resignFirstResponder()
        savedSelection = view.selectedRange
        view.delegate?.textViewDidChange?(view)
    }

    func cancelPausedEditing() { savedSelection = nil }

    static func caretRange(at offset: Int, in text: String) -> NSRange {
        let source = text as NSString
        let offset = min(max(offset, 0), source.length)
        let location = offset == source.length ? offset : source.rangeOfComposedCharacterSequence(at: offset).location
        return NSRange(location: location, length: 0)
    }

    func insertEmoticon(_ item: ForumEmoticon, isBlog: Bool, encodeHTML: Bool) {
        if usesBBCodeDocument { _ = bbcodeSession.insertMarkup(item.code); return }
        if isVisual, let view, let richSession {
            restoreSelection(in: view)
            richSession.insertEmoticon(item, in: view)
            return
        }
        let markup = isBlog
            ? "<img src=\"\(ForumPageSession.htmlFromPlainText(item.imageURL.absoluteString))\" alt=\"\(ForumPageSession.htmlFromPlainText(item.code))\">"
            : item.code
        replaceSelection(before: markup, after: "", placeholder: "", encodeHTML: encodeHTML, keepsSelection: false)
    }

    func wrap(before: String, after: String, placeholder: String, encodeHTML: Bool) {
        if usesBBCodeDocument {
            let document = ForumComposerDocument(source: before + "x" + after)
            if let node = document.nodes.first, let tag = node.tag { bbcodeSession.format(tag, parameter: node.parameter) }
            return
        }
        if isVisual, let view, let richSession {
            restoreSelection(in: view)
            richSession.wrap(before: before, after: after, placeholder: placeholder, in: view)
            return
        }
        replaceSelection(before: before, after: after, placeholder: placeholder, encodeHTML: encodeHTML, keepsSelection: true)
    }

    private func restoreSelection(in view: UITextView) {
        view.unmarkText()
        if let savedSelection, NSMaxRange(savedSelection) <= view.attributedText.length { view.selectedRange = savedSelection }
        savedSelection = nil
    }

    private func replaceSelection(before: String, after: String, placeholder: String, encodeHTML: Bool, keepsSelection: Bool) {
        guard let view else { return }
        view.unmarkText()
        let source = view.text ?? ""
        let selectedRange = savedSelection ?? view.selectedRange
        savedSelection = nil
        guard let selection = Range(selectedRange, in: source) else { return }
        let encode: (String) -> String = encodeHTML ? ForumPageSession.htmlFromPlainText : { $0 }
        let prefix = encode(String(source[..<selection.lowerBound]))
        let suffix = encode(String(source[selection.upperBound...]))
        let selected = keepsSelection ? (source[selection].isEmpty ? placeholder : String(source[selection])) : ""
        let replacement = prefix + before + encode(selected) + after + suffix
        let oldRange = selectedRange
        view.undoManager?.registerUndo(withTarget: view) { view in
            view.text = source
            view.selectedRange = oldRange
            view.delegate?.textViewDidChange?(view)
        }
        view.text = replacement
        view.selectedRange = NSRange(location: (prefix + before + encode(selected)).utf16.count, length: 0)
        view.delegate?.textViewDidChange?(view)
        view.becomeFirstResponder()
    }

    func undo() { if usesBBCodeDocument { bbcodeSession.undo() } else { view?.undoManager?.undo() } }
}

struct ForumTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isHTMLSource: Bool
    let isBlog: Bool
    let mode: ForumComposerMode
    let controller: ForumEditorController
    @Environment(\.forumTheme) private var theme
    @Environment(\.yamiboImagePipeline) private var imagePipeline
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 17

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isHTMLSource: $isHTMLSource, isBlog: isBlog, controller: controller) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .systemFont(ofSize: bodyFontSize)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "native-composer-body"
        controller.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isHTMLSource = $isHTMLSource
        let modeChanged = context.coordinator.mode != mode
        let fontChanged = context.coordinator.baseFontSize != bodyFontSize
        context.coordinator.mode = mode
        controller.isVisual = mode == .visual
        if modeChanged { view.undoManager?.removeAllActions() }
        if view.markedTextRange == nil {
            context.coordinator.baseFontSize = bodyFontSize
            if mode == .visual {
                if controller.richSession == nil { controller.richSession = ForumRichEditorSession() }
                controller.richSession?.theme = theme
                controller.richSession?.baseFontSize = bodyFontSize
                if controller.richSession?.load(source: text, format: isBlog ? (isHTMLSource ? .html : .plainText) : .bbcode, into: view, force: modeChanged || fontChanged) == true {
                    context.coordinator.cancelImageLoads()
                }
            } else if modeChanged || fontChanged || view.text != text {
                let selected = view.selectedRange
                view.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular), .foregroundColor: UIColor.label])
                view.selectedRange = ForumEditorController.caretRange(at: selected.location, in: text)
                context.coordinator.cancelImageLoads()
            }
        }
        context.coordinator.updateEditability(context.environment.isEnabled, in: view)
        context.coordinator.loadImages(in: view, pipeline: imagePipeline)
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.invalidateEditabilityUpdate()
        coordinator.cancelImageLoads()
        view.delegate = nil
        if coordinator.controller.view === view { coordinator.controller.view = nil }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isHTMLSource: Binding<Bool>
        let isBlog: Bool
        let controller: ForumEditorController
        var mode: ForumComposerMode?
        var baseFontSize: CGFloat?
        private var isEditingEnabled = true
        private var editabilityRevision = 0
        private var imageTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var pendingEdit: (source: NSString, range: NSRange, attributes: [NSAttributedString.Key: Any])?

        init(text: Binding<String>, isHTMLSource: Binding<Bool>, isBlog: Bool, controller: ForumEditorController) {
            self.text = text
            self.isHTMLSource = isHTMLSource
            self.isBlog = isBlog
            self.controller = controller
        }

        func updateEditability(_ isEnabled: Bool, in view: UITextView) {
            isEditingEnabled = isEnabled
            editabilityRevision += 1
            guard view.isEditable != isEnabled else { return }
            let revision = editabilityRevision
            // setEditable can resign first responder and reenter SwiftUI's graph.
            // Defer that UIKit work, but reject input immediately through the delegate.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.editabilityRevision == revision,
                      self.controller.view === view, view.isEditable != self.isEditingEnabled else { return }
                view.isEditable = self.isEditingEnabled
            }
        }

        func invalidateEditabilityUpdate() {
            isEditingEnabled = false
            editabilityRevision += 1
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { isEditingEnabled }

        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            if mode == .visual, let edit = pendingEdit {
                pendingEdit = nil
                let text = textView.text as NSString
                let length = text.length - edit.source.length + edit.range.length
                let range = NSRange(location: edit.range.location, length: max(0, length))
                if length >= 0, NSMaxRange(range) <= text.length,
                   text.substring(to: range.location) == edit.source.substring(to: edit.range.location),
                   text.substring(from: NSMaxRange(range)) == edit.source.substring(from: NSMaxRange(edit.range)) {
                    // TextKit preserves fonts but drops custom attributes while
                    // typing. Restore only source metadata after IME commits.
                    ForumRichTextCodec.restoreTypingMetadata(in: textView.textStorage, range: range, attributes: edit.attributes)
                }
            }
            let value = mode == .visual ? controller.richSession?.sourceAfterEditing(textView) ?? textView.text! : textView.text!
            if value != text.wrappedValue {
                text.wrappedValue = value
                if isBlog && mode == .visual { isHTMLSource.wrappedValue = true }
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard mode == .visual, textView.markedTextRange == nil else { return }
            textView.typingAttributes = ForumRichTextCodec.typingAttributes(in: textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard isEditingEnabled else { return false }
            if mode == .visual && (textView.markedTextRange == nil || pendingEdit == nil) {
                let attributes = ForumRichTextCodec.typingAttributes(in: textView)
                pendingEdit = (textView.text as NSString, range, attributes)
                if textView.markedTextRange == nil { textView.typingAttributes = attributes }
            }
            return true
        }

        func cancelImageLoads() {
            imageTasks.values.forEach { $0.cancel() }
            imageTasks = [:]
        }

        func loadImages(in view: UITextView, pipeline: YamiboUIImagePipeline?) {
            guard mode == .visual, let pipeline else { return }
            view.attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.attributedText.length)) { value, _, _ in
                guard let attachment = value as? ForumComposerImageAttachment, let url = attachment.imageURL,
                      imageTasks[ObjectIdentifier(attachment)] == nil else { return }
                imageTasks[ObjectIdentifier(attachment)] = Task { [weak view] in
                    guard let image = try? await pipeline.image(for: YamiboImageSource(url: url, refererPageURL: YamiboDomain.baseURL)), !Task.isCancelled else { return }
                    attachment.image = image
                    let dimension = max(attachment.bounds.width, attachment.bounds.height)
                    let scale = dimension / max(image.size.width, image.size.height, 1)
                    attachment.bounds.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    if let view {
                        view.textStorage.edited(.editedAttributes, range: NSRange(location: 0, length: view.textStorage.length), changeInLength: 0)
                    }
                }
            }
        }
    }
}

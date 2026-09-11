import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YamiboXCore

@MainActor
final class ForumBBCodeTextView: UITextView {
    static let fragmentType = "com.arkalin.yamibox.bbcode-fragment"
    weak var session: ForumBBCodeSession?
    var pasteboard: UIPasteboard = .general
    override var undoManager: UndoManager? { nil }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoDocument)),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoDocument)),
         UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(boldDocument)),
         UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(italicDocument))]
    }

    @objc private func undoDocument() { session?.undo() }
    @objc private func redoDocument() { session?.redo() }
    @objc private func boldDocument() { session?.format(.b) }
    @objc private func italicDocument() { session?.format(.i) }

    override func copy(_ sender: Any?) {
        guard let session else { super.copy(sender); return }
        session.commitComposition()
        let fragment = session.isVisual ? session.document.fragment(in: .init(selectedRange), parsesEmoticons: session.parsesEmoticons) : session.document.substring(.init(selectedRange))
        let plain = session.isVisual ? ForumComposerDocument(source: fragment).plainText() : fragment
        let provider = NSItemProvider()
        for (type, value) in [(Self.fragmentType, fragment), (UTType.utf8PlainText.identifier, plain)] {
            let data = Data(value.utf8)
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        pasteboard.setItemProviders([provider], localOnly: true, expirationDate: nil)
    }

    override func cut(_ sender: Any?) {
        guard isEditable, let session else { return }
        copy(sender)
        session.perform(session.isVisual ? .replaceVisible(.init(selectedRange), "") : .replaceSource(.init(selectedRange), ""))
    }

    override func paste(_ sender: Any?) {
        guard isEditable, let session else { return }
        session.commitComposition()
        let board = pasteboard
        let clipboardRevision = board.changeCount
        guard let provider = board.itemProviders.first else { return }
        let anchor = session.bookmark()
        Task { [weak self, weak session] in
            guard let session else { return }
            defer { session.removeBookmark(anchor) }
            let types = [Self.fragmentType] + (session.isVisual ? [UTType.html.identifier] : [])
                + [UTType.png.identifier, UTType.jpeg.identifier, UTType.utf8PlainText.identifier]
            guard let type = types.first(where: provider.hasItemConformingToTypeIdentifier) else { return }
            let data: Data
            do { data = try await Self.pasteData(from: provider, type: type) }
            catch {
                guard let self, self.isEditable, session.view === self, session.bookmarkedSelection(anchor) != nil else { return }
                // Some image pasteboards expose a UIImage but cannot vend its advertised raw representation.
                if board.changeCount == clipboardRevision, [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
                   let imageData = board.data(forPasteboardType: type) ?? board.image?.pngData() {
                    data = imageData
                } else {
                    session.errorMessage = error.localizedDescription
                    return
                }
            }
            guard let self, self.isEditable, session.view === self,
                  let selection = session.bookmarkedSelection(anchor) else { return }
            if type == UTType.png.identifier || type == UTType.jpeg.identifier {
                session.restoreState(sourceMode: session.sourceMode, selection: selection)
                if let onPasteImage = session.onPasteImage { onPasteImage(data) }
                else { session.errorMessage = ForumPageError.unsupportedUpload.localizedDescription }
            } else if let text = String(data: data, encoding: .utf8) {
                let source = type == UTType.html.identifier ? try? ForumComposerClipboard.importHTML(text) : text
                if let source { _ = session.insertMarkup(source, at: anchor) }
            }
        }
    }

    static func pasteData(from provider: NSItemProvider, type: String) async throws -> Data {
        let read = ClipboardDataRead()
        return try await withCheckedThrowingContinuation { continuation in
            read.continuation = continuation
            read.progress = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                Task { @MainActor in
                    read.finish(data.map(Result.success) ?? .failure(error ?? CocoaError(.fileReadCorruptFile)))
                }
            }
            read.timeout = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                read.progress?.cancel()
                read.finish(.failure(URLError(.timedOut)))
            }
        }
    }
}

@MainActor
private final class ClipboardDataRead {
    var continuation: CheckedContinuation<Data, any Error>?
    var progress: Progress?
    var timeout: Task<Void, Never>?
    func finish(_ result: Result<Data, any Error>) {
        timeout?.cancel(); timeout = nil
        continuation?.resume(with: result); continuation = nil
        progress = nil
    }
}

struct ForumBBCodeTextEditor: UIViewRepresentable {
    @Binding var text: String
    let controller: ForumEditorController
    let composerContext: ForumComposerContext
    var parsesBBCode = true
    var parsesEmoticons = true
    var isFullScreen = false
    @Environment(\.forumTheme) private var theme
    @Environment(\.yamiboImagePipeline) private var imagePipeline
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 17

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, session: controller.bbcodeSession) }

    func makeUIView(context: Context) -> ForumBBCodeTextView {
        let view = ForumBBCodeTextView(usingTextLayoutManager: true)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "native-composer-body"
        view.accessibilityLabel = L10n.string("forum.native.message")
        controller.usesBBCodeDocument = true
        if controller.bbcodeSession.isFullScreen == isFullScreen {
            controller.view = view
            controller.bbcodeSession.attach(view)
        }
        return view
    }

    func updateUIView(_ view: ForumBBCodeTextView, context: Context) {
        let session = controller.bbcodeSession
        context.coordinator.text = $text
        // A dismissed surface can receive a final update after its replacement has mounted.
        guard session.isFullScreen == isFullScreen else { return }
        let reattached = session.view !== view
        controller.view = view
        session.attach(view)
        let changed = session.baseFontSize != bodyFontSize || session.theme.id != theme.id || session.parsesBBCode != parsesBBCode || session.parsesEmoticons != parsesEmoticons || session.context != composerContext
        session.theme = theme
        session.baseFontSize = bodyFontSize
        session.context = composerContext
        session.parsesBBCode = parsesBBCode
        session.parsesEmoticons = parsesEmoticons
        session.imagePipeline = imagePipeline
        if changed { session.invalidateAttachments() }
        session.onSourceChange = { [weak coordinator = context.coordinator] source in
            guard let coordinator, coordinator.text.wrappedValue != source else { return }
            coordinator.text.wrappedValue = source
        }
        session.load(text, force: changed || reattached || view.textStorage.length == 0 && !text.isEmpty)
        context.coordinator.updateEnabled(context.environment.isEnabled, view: view)
    }

    static func dismantleUIView(_ view: ForumBBCodeTextView, coordinator: Coordinator) {
        coordinator.revision += 1
        view.delegate = nil
        if coordinator.session.view === view { coordinator.session.view = nil }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        let session: ForumBBCodeSession
        var enabled = true
        var revision = 0
        init(text: Binding<String>, session: ForumBBCodeSession) { self.text = text; self.session = session }

        func updateEnabled(_ value: Bool, view: ForumBBCodeTextView) {
            enabled = value
            revision += 1
            guard view.isEditable != value else { return }
            let expected = revision
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.revision == expected else { return }
                view.isEditable = value
            }
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { enabled && session.view === textView }
        func textViewDidChange(_ textView: UITextView) {
            guard session.view === textView else { return }
            session.isComposing = textView.markedTextRange != nil
            guard textView.markedTextRange == nil, !session.isRendering else { return }
            session.textChanged(from: session.projection.text, to: textView.text ?? "", visibleSelection: textView.selectedRange)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard session.view === textView else { return }
            session.isComposing = textView.markedTextRange != nil
            guard !session.isRendering, textView.markedTextRange == nil else { return }
            session.captureSelection(userInitiated: true)
            session.updateTypingAttributes()
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard enabled, session.view === textView else { return false }
            if textView.markedTextRange == nil, session.isVisual, session.handleListInput(range: range, text: text) { return false }
            if text.isEmpty, range.length == 1, session.isVisual,
               session.projection.spans.contains(where: { $0.kind == .boundary && $0.range.intersection(.init(range)) != nil }),
               let previous = session.projection.spans.last(where: { $0.isAtomic && $0.range.end == range.location }) {
                textView.selectedRange = previous.range.nsRange
                session.captureSelection()
                return false
            }
            return true
        }
    }
}

import SwiftUI
import UIKit
import YamiboXCore

private extension NSAttributedString.Key {
    static let forumComposerRun = Self("yamibox.composer.run")
}

private final class ForumComposerRunBox: NSObject {
    let run: ForumComposerRun
    init(_ run: ForumComposerRun) { self.run = run }
}

final class ForumComposerImageAttachment: NSTextAttachment {
    let imageURL: URL?

    init(run: ForumComposerRun) {
        imageURL = run.imageURL
        super.init(data: nil, ofType: nil)
        image = UIImage(systemName: run.imageURL == nil ? "paperclip" : "photo")?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
        let dimension: CGFloat = run.source.hasPrefix("{:") || run.imageURL?.path.contains("/smiley/") == true ? 32 : 120
        bounds = CGRect(x: 0, y: -4, width: dimension, height: dimension)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
enum ForumRichTextCodec {
    static func attributedText(source: String, format: ForumComposerFormat, theme: ForumTheme, baseFontSize: CGFloat = 17) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in ForumComposerMarkup.parse(source, format: format) {
            var attributes = attributes(for: run, theme: theme, baseFontSize: baseFontSize)
            if run.isAttachment { attributes[.attachment] = ForumComposerImageAttachment(run: run) }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    static func runs(in text: NSAttributedString) -> [ForumComposerRun] {
        var runs: [ForumComposerRun] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let value = (text.string as NSString).substring(with: range)
            var run = (attributes[.forumComposerRun] as? ForumComposerRunBox)?.run ?? .init(text: "", source: "")
            run.text = value
            runs.append(run)
        }
        return runs
    }

    static func run(from attributes: [NSAttributedString.Key: Any]) -> ForumComposerRun {
        (attributes[.forumComposerRun] as? ForumComposerRunBox)?.run ?? .init(text: "", source: "")
    }

    static func typingAttributes(from attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let previous = run(from: attributes)
        var result = attributes
        result.removeValue(forKey: .attachment)
        // New characters inherit formatting, never an image's serialized source.
        result[.forumComposerRun] = ForumComposerRunBox(.init(text: "", source: "", wrappers: previous.wrappers,
                                                           isLiteral: previous.isLiteral && !previous.isAttachment))
        return result
    }

    static func typingAttributes(in view: UITextView) -> [NSAttributedString.Key: Any] {
        var attributes = view.typingAttributes
        if attributes[.forumComposerRun] == nil && view.attributedText.length > 0 {
            let selection = view.selectedRange
            let index = min(selection.length > 0 ? selection.location : max(0, selection.location - 1), view.attributedText.length - 1)
            attributes[.forumComposerRun] = view.attributedText.attribute(.forumComposerRun, at: index, effectiveRange: nil)
        }
        return typingAttributes(from: attributes)
    }

    static func restoreTypingMetadata(in text: NSMutableAttributedString, range: NSRange, attributes: [NSAttributedString.Key: Any]) {
        if let run = attributes[.forumComposerRun], range.length > 0 {
            text.addAttribute(.forumComposerRun, value: run, range: range)
        }
    }

    static func attributes(for run: ForumComposerRun, theme: ForumTheme, baseFontSize: CGFloat = 17) -> [NSAttributedString.Key: Any] {
        var style = ForumThreadTextStyle()
        for wrapper in run.wrappers {
            style.isBold = style.isBold || wrapper.style.isBold
            style.isItalic = style.isItalic || wrapper.style.isItalic
            style.isUnderline = style.isUnderline || wrapper.style.isUnderline
            style.isStrikethrough = style.isStrikethrough || wrapper.style.isStrikethrough
            style.foregroundHex = wrapper.style.foregroundHex ?? style.foregroundHex
            style.backgroundHex = wrapper.style.backgroundHex ?? style.backgroundHex
            style.relativeFontSize = wrapper.style.relativeFontSize ?? style.relativeFontSize
        }
        let pointSize = baseFontSize * CGFloat(min(max(style.relativeFontSize ?? 1, 0.7), 2))
        var font = run.isLiteral ? UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular) : UIFont.systemFont(ofSize: pointSize)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.isBold { traits.insert(.traitBold) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: pointSize) }
        if style.isItalic {
            // Slant the upright face so CJK fallback glyphs lean too, without double-slanting Latin.
            let matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            font = UIFont(descriptor: font.fontDescriptor.withMatrix(matrix), size: pointSize)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        if run.wrappers.contains(where: \.isQuote) {
            paragraph.firstLineHeadIndent = 16
            paragraph.headIndent = 16
        }
        let colors = ForumThreadAuthorColorAdapter.colors(for: style, theme: theme)
        var result: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: colors.foreground.map(UIColor.init) ?? UIColor.label,
            .paragraphStyle: paragraph, .forumComposerRun: ForumComposerRunBox(run)
        ]
        if let color = colors.background { result[.backgroundColor] = UIColor(color) }
        else if run.wrappers.contains(where: \.isQuote) { result[.backgroundColor] = UIColor.secondarySystemBackground }
        if style.isUnderline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.isStrikethrough { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if !run.wrappers.compactMap(\.link).isEmpty {
            result[.foregroundColor] = UIColor(theme.accentText)
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
    }
}

@MainActor
final class ForumRichEditorSession {
    private(set) var source = ""
    private(set) var format: ForumComposerFormat = .bbcode
    private var committedMarkup = ""
    private var restoredSource: String?
    private var isPlainTextSource = false
    var theme: ForumTheme = .classic
    var baseFontSize: CGFloat = 17

    func load(source: String, format: ForumComposerFormat, into view: UITextView, force: Bool = false) -> Bool {
        guard force || source != self.source else { return false }
        self.source = source
        self.format = format == .bbcode ? .bbcode : .html
        isPlainTextSource = format == .plainText
        let selection = view.selectedRange
        let text = ForumRichTextCodec.attributedText(source: source, format: format, theme: theme, baseFontSize: baseFontSize)
        view.attributedText = text
        committedMarkup = ForumComposerMarkup.serialize(ForumRichTextCodec.runs(in: text), format: self.format)
        view.selectedRange = ForumEditorController.caretRange(at: selection.location, in: text.string)
        let attributes = text.length > 0
            ? text.attributes(at: max(0, view.selectedRange.location - 1), effectiveRange: nil)
            : ForumRichTextCodec.attributes(for: .init(text: "", source: ""), theme: theme, baseFontSize: baseFontSize)
        view.typingAttributes = ForumRichTextCodec.typingAttributes(from: attributes)
        return true
    }

    func sourceAfterEditing(_ view: UITextView) -> String {
        let markup = ForumComposerMarkup.serialize(ForumRichTextCodec.runs(in: view.attributedText), format: format)
        if let restoredSource {
            source = restoredSource
            self.restoredSource = nil
            isPlainTextSource = false
        } else if committedMarkup != markup {
            source = markup
            isPlainTextSource = false
        }
        committedMarkup = markup
        return source
    }

    func wrap(before: String, after: String, placeholder: String, in view: UITextView) {
        guard let parsed = ForumComposerMarkup.parse(before + "x" + after, format: format).first?.wrappers.last else { return }
        let wrapper = ForumComposerWrapper(id: UUID().uuidString, name: parsed.name, opening: parsed.opening, closing: parsed.closing,
                                           style: parsed.style, link: parsed.link, isQuote: parsed.isQuote)
        let selection = view.selectedRange
        if selection.length == 0 && !placeholder.isEmpty {
            insert(NSAttributedString(string: placeholder, attributes: view.typingAttributes), in: view)
            view.selectedRange = NSRange(location: selection.location, length: placeholder.utf16.count)
            wrap(before: before, after: after, placeholder: "", in: view)
            return
        }
        if selection.length == 0 {
            var run = ForumRichTextCodec.run(from: view.typingAttributes)
            toggle(wrapper, in: &run)
            view.typingAttributes = ForumRichTextCodec.attributes(for: run, theme: theme, baseFontSize: baseFontSize)
            view.becomeFirstResponder()
            return
        }
        registerUndo(in: view)
        let changed = NSMutableAttributedString(attributedString: view.attributedText)
        var slices: [(NSRange, [NSAttributedString.Key: Any])] = []
        changed.enumerateAttributes(in: selection) { attributes, range, _ in slices.append((range, attributes)) }
        let removing = slices.allSatisfy { ForumRichTextCodec.run(from: $0.1).wrappers.contains { $0.formattingName == wrapper.formattingName } }
        for (range, attributes) in slices {
            var run = ForumRichTextCodec.run(from: attributes)
            run.wrappers.removeAll { $0.formattingName == wrapper.formattingName }
            if !removing { run.wrappers.append(wrapper) }
            var updated = ForumRichTextCodec.attributes(for: run, theme: theme, baseFontSize: baseFontSize)
            updated[.attachment] = attributes[.attachment]
            changed.setAttributes(updated, range: range)
        }
        view.attributedText = changed
        view.selectedRange = selection
        view.delegate?.textViewDidChange?(view)
        view.becomeFirstResponder()
    }

    func insertEmoticon(_ item: ForumEmoticon, in view: UITextView) {
        let markup = format == .bbcode ? item.code : "<img src=\"\(ForumComposerMarkup.escapeHTML(item.imageURL.absoluteString))\" alt=\"\(ForumComposerMarkup.escapeHTML(item.code))\">"
        let run = ForumComposerRun(text: "\u{FFFC}", source: markup,
                                   wrappers: ForumRichTextCodec.run(from: view.typingAttributes).wrappers,
                                   imageURL: item.imageURL, isAttachment: true)
        var attributes = ForumRichTextCodec.attributes(for: run, theme: theme, baseFontSize: baseFontSize)
        attributes[.attachment] = ForumComposerImageAttachment(run: run)
        insert(NSAttributedString(string: run.text, attributes: attributes), in: view)
    }

    private func toggle(_ wrapper: ForumComposerWrapper, in run: inout ForumComposerRun) {
        if run.wrappers.contains(where: { $0.formattingName == wrapper.formattingName }) {
            run.wrappers.removeAll { $0.formattingName == wrapper.formattingName }
        } else { run.wrappers.append(wrapper) }
    }

    private func insert(_ text: NSAttributedString, in view: UITextView) {
        registerUndo(in: view)
        let selection = view.selectedRange
        let changed = NSMutableAttributedString(attributedString: view.attributedText)
        changed.replaceCharacters(in: selection, with: text)
        let typing = view.typingAttributes
        view.attributedText = changed
        view.selectedRange = NSRange(location: selection.location + text.length, length: 0)
        view.typingAttributes = typing
        view.delegate?.textViewDidChange?(view)
        view.becomeFirstResponder()
    }

    private func registerUndo(in view: UITextView) {
        let previousText = view.attributedText.copy() as? NSAttributedString ?? view.attributedText!
        let previousRange = view.selectedRange
        let previousSource = isPlainTextSource ? ForumComposerMarkup.escapeHTML(source) : source
        view.undoManager?.registerUndo(withTarget: self) { [weak view] session in
            guard let view else { return }
            view.attributedText = previousText
            view.selectedRange = previousRange
            session.restoredSource = previousSource
            view.delegate?.textViewDidChange?(view)
        }
    }
}

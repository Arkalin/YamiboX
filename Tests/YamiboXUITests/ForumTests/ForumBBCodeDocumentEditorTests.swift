import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ForumBBCodeDocumentEditorTests: XCTestCase {
    func testDismissedTextViewCannotCommitOrDetachItsReplacement() {
        let fixture = BBCodeEditorFixture("[b]Keep body[/b]")
        let replacement = ForumBBCodeTextView(usingTextLayoutManager: true)
        fixture.session.attach(replacement)
        fixture.session.load(fixture.session.source, force: true)
        fixture.view.text = "stale surface"
        fixture.coordinator.textViewDidChange(fixture.view)
        ForumBBCodeTextEditor.dismantleUIView(fixture.view, coordinator: fixture.coordinator)
        XCTAssertTrue(fixture.session.view === replacement)
        XCTAssertEqual(fixture.session.source, "[b]Keep body[/b]")
        fixture.session.setSourceMode(true)
        XCTAssertEqual(replacement.text, "[b]Keep body[/b]")
    }

    func testWrappedListKeepsHangingIndentWhileTyping() throws {
        let fixture = BBCodeEditorFixture("[list=1][*]First item with enough text to wrap[*]Second[/list]")
        let marker = try XCTUnwrap(fixture.session.projection.spans.first { if case .listMarker = $0.kind { true } else { false } })
        let attachment = try XCTUnwrap(fixture.session.attachment(for: marker))
        let paragraph = try XCTUnwrap(fixture.view.textStorage.attribute(.paragraphStyle, at: marker.range.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.headIndent - paragraph.firstLineHeadIndent, attachment.size(maxWidth: 640).width, accuracy: 0.01)
        fixture.view.selectedRange = NSRange(location: marker.range.end + 2, length: 0)
        fixture.coordinator.textViewDidChangeSelection(fixture.view)
        let typing = try XCTUnwrap(fixture.view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(typing.headIndent, paragraph.headIndent)
        fixture.view.insertText("x")
        fixture.coordinator.textViewDidChange(fixture.view)
        XCTAssertTrue(fixture.session.source.contains("Fixrst"))
    }

    func testUnchangedPropertyPanelsPreserveNoncanonicalParameters() {
        let samples: [(ForumComposerTag, String)] = [(.font, "Unknown Font"), (.size, "12PT"), (.color, "Red"), (.backcolor, "#eee"),
            (.align, "right"), (.p, "null, null, right"), (.lineh, "1.70"), (.collapse, "1,Title, with comma"), (.hide, "d7,100"),
            (.float, "right"), (.img, "80%,auto"), (.audio, "1"), (.media, "mp4,80%,auto"), (.flash, "640,480"),
            (.begin, "https://example.com/,900,500,2,5"), (.ruby, "reading"), (.url, "home.php?mod=space&uid=1")]
        for (tag, parameter) in samples {
            let request = ForumComposerNodeEditRequest(nodeID: "test", tag: tag, parameter: parameter, body: "body", originalSource: nil, anchorID: UUID())
            let model = ForumComposerNodePanelModel(request: request)
            XCTAssertEqual(model.parameter, parameter, tag.rawValue)
            XCTAssertEqual(model.body, "body")
        }
    }
    func testEmptyColorPanelChangesTypingStyleWithoutInsertingEmptyTags() throws {
        let fixture = BBCodeEditorFixture("ab")
        fixture.view.selectedRange = NSRange(location: 1, length: 0)
        fixture.session.insertNode(.color)
        let request = try XCTUnwrap(fixture.session.nodeRequest)
        XCTAssertTrue(fixture.session.saveNode(request, parameter: "#FF0000", body: ""))
        XCTAssertEqual(fixture.session.source, "ab")
        fixture.view.insertText("X")
        fixture.coordinator.textViewDidChange(fixture.view)
        XCTAssertEqual(fixture.session.source, "a[color=#FF0000]X[/color]b")
    }

    func testNestedImagesAppearInBlockPreviewsWithoutChangingSource() throws {
        let fixture = BBCodeEditorFixture("[collapse=1,title][attachimg]12[/attachimg][/collapse]")
        let span = try XCTUnwrap(fixture.session.projection.spans.first { $0.kind == .atomic })
        let attachment = try XCTUnwrap(fixture.session.attachment(for: span))
        let before = fixture.session.source
        fixture.session.localImages["12"] = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50)).image { context in
            UIColor.systemRed.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        }
        var hasImage = false
        attachment.bodyPreview.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attachment.bodyPreview.length)) { value, _, _ in
            if (value as? NSTextAttachment)?.image != nil { hasImage = true }
        }
        XCTAssertTrue(hasImage)
        XCTAssertEqual(fixture.session.source, before)
        XCTAssertFalse(fixture.session.canUndo)
    }

    func testMovingCaretClearsPendingTypingMarks() {
        let fixture = BBCodeEditorFixture("abcd")
        fixture.view.selectedRange = NSRange(location: 1, length: 0)
        fixture.session.captureSelection()
        fixture.session.format(.b)
        fixture.view.selectedRange = NSRange(location: 3, length: 0)
        fixture.coordinator.textViewDidChangeSelection(fixture.view)
        fixture.view.insertText("X")
        fixture.coordinator.textViewDidChange(fixture.view)
        XCTAssertEqual(fixture.session.source, "abcXd")
    }

    func testPostPasswordIsAPropertyAndNeverReplacesSelectedBody() throws {
        let fixture = BBCodeEditorFixture("keep body")
        fixture.view.selectedRange = NSRange(location: 0, length: 9)
        fixture.session.insertNode(.password)
        let request = try XCTUnwrap(fixture.session.nodeRequest)
        XCTAssertEqual(request.body, "")
        XCTAssertTrue(fixture.session.saveNode(request, parameter: "", body: "secret"))
        XCTAssertEqual(fixture.session.source, "[password]secret[/password]\nkeep body")
        fixture.session.insertNode(.password)
        XCTAssertNotNil(fixture.session.nodeRequest?.nodeID)
    }

    func testNativeDocumentTypingCommitsIMEOnceAndUndoSurvivesSourceMode() throws {
        let fixture = BBCodeEditorFixture("[b]前[/b]")
        XCTAssertNotNil(fixture.view.textLayoutManager)
        fixture.view.selectedRange = NSRange(location: 1, length: 0)
        fixture.session.captureSelection()
        fixture.view.setMarkedText("组词", selectedRange: NSRange(location: 2, length: 0))
        fixture.coordinator.textViewDidChange(fixture.view)
        XCTAssertEqual(fixture.session.source, "[b]前[/b]")
        XCTAssertTrue(fixture.session.isComposing)
        fixture.session.commitComposition()
        XCTAssertFalse(fixture.session.isComposing)
        XCTAssertEqual(fixture.view.text, "前组词")
        XCTAssertEqual(fixture.session.source, "[b]前组词[/b]")
        fixture.session.setSourceMode(true)
        XCTAssertEqual(fixture.view.text, "[b]前组词[/b]")
        fixture.session.undo()
        XCTAssertEqual(fixture.view.text, "[b]前[/b]")
        fixture.session.redo()
        fixture.session.setSourceMode(false)
        XCTAssertEqual(fixture.view.text, "前组词")
        XCTAssertEqual(fixture.session.source, "[b]前组词[/b]")
    }

    func testTypingMarksAndPartialRemovalDoNotLoseHiddenBlocks() throws {
        let fixture = BBCodeEditorFixture("[B]ab[/B][hide=d7,100]hidden[/hide]")
        fixture.view.selectedRange = NSRange(location: 1, length: 0)
        fixture.session.captureSelection()
        fixture.session.format(.b)
        XCTAssertEqual(fixture.session.source, "[B]ab[/B][hide=d7,100]hidden[/hide]")
        fixture.view.insertText("X")
        fixture.coordinator.textViewDidChange(fixture.view)
        XCTAssertEqual(fixture.session.source, "[B]a[/B]X[B]b[/B][hide=d7,100]hidden[/hide]")
        XCTAssertTrue(fixture.session.document.diagnostics.isEmpty)
        fixture.session.undo()
        XCTAssertEqual(fixture.session.source, "[B]ab[/B][hide=d7,100]hidden[/hide]")
    }

    func testBlockPanelsCommitAtomicallyCancelAndRejectStaleContent() throws {
        let fixture = BBCodeEditorFixture("prefix[collapse=0,title][b]body[/b][/collapse]suffix")
        let node = try XCTUnwrap(fixture.session.document.nodes.first { $0.tag == .collapse })
        fixture.session.editNode(node.id)
        let cancelled = try XCTUnwrap(fixture.session.nodeRequest)
        fixture.session.cancelNodeEditing()
        XCTAssertTrue(fixture.session.source.contains(cancelled.originalSource!))
        fixture.session.editNode(node.id)
        let request = try XCTUnwrap(fixture.session.nodeRequest)
        XCTAssertTrue(fixture.session.saveNode(request, parameter: "1,new", body: "[ruby=读音]文字[/ruby]"))
        XCTAssertEqual(fixture.session.source, "prefix[collapse=1,new][ruby=读音]文字[/ruby][/collapse]suffix")
        fixture.session.undo()
        XCTAssertEqual(fixture.session.source, "prefix[collapse=0,title][b]body[/b][/collapse]suffix")
        let restored = try XCTUnwrap(fixture.session.document.nodes.first { $0.tag == .collapse })
        fixture.session.editNode(restored.id)
        let stale = try XCTUnwrap(fixture.session.nodeRequest)
        fixture.session.perform(.replaceSource(.init(location: restored.contentRange.location), "changed"))
        XCTAssertFalse(fixture.session.saveNode(stale, parameter: "0,title", body: "must not replace"))
        XCTAssertTrue(fixture.session.source.contains("changed"))
    }

    func testUploadAnchorsMoveAndDeletedAnchorsNeverAppendElsewhere() {
        let fixture = BBCodeEditorFixture("abcd")
        fixture.view.selectedRange = NSRange(location: 2, length: 0)
        let anchor = fixture.session.bookmark()
        fixture.session.perform(.replaceSource(.init(location: 0), "前"))
        XCTAssertTrue(fixture.session.insertMarkup("[attachimg]1[/attachimg]", at: anchor))
        XCTAssertEqual(fixture.session.source, "前ab[attachimg]1[/attachimg]cd")
        fixture.session.setSourceMode(true)
        fixture.view.selectedRange = NSRange(location: 2, length: 0)
        let removed = fixture.session.bookmark()
        fixture.session.perform(.replaceSource(.init(location: 0, length: 4), "new"))
        let before = fixture.session.source
        XCTAssertFalse(fixture.session.insertMarkup("[attachimg]2[/attachimg]", at: removed))
        XCTAssertEqual(fixture.session.source, before)
    }

    func testAtomicCopyIncludesSourceAndPlainTextMasksPostPassword() async throws {
        let fixture = BBCodeEditorFixture("[password]secret[/password][ruby=reading]base[/ruby]")
        let name = UIPasteboard.Name("bbcode-tests-" + UUID().uuidString)
        fixture.view.pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        fixture.view.selectedRange = NSRange(location: 0, length: fixture.view.textStorage.length)
        fixture.view.copy(nil)
        // Pasteboard change notifications must finish before a same-process read.
        try await Task.sleep(for: .milliseconds(100))
        let provider = try XCTUnwrap(fixture.view.pasteboard.itemProviders.first)
        let data = try await ForumBBCodeTextView.pasteData(from: provider, type: ForumBBCodeTextView.fragmentType)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("[password]secret[/password]"))
        let plain = try await ForumBBCodeTextView.pasteData(from: provider, type: "public.utf8-plain-text")
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("secret"))
        fixture.view.selectedRange = NSRange(location: 0, length: 1)
        fixture.view.cut(nil)
        XCTAssertFalse(fixture.session.source.contains("secret"))
        XCTAssertTrue(fixture.session.source.contains("[ruby=reading]base[/ruby]"))
        fixture.session.undo()
        XCTAssertTrue(fixture.session.source.contains("[password]secret[/password]"))
    }

    func testNativeAttributesKeepFontNameSourceSizesAndCJKSlant() throws {
        let fixture = BBCodeEditorFixture("[font=NotInstalledFont][size=12pt][i]中文[/i][/size][/font][sup]2[/sup]")
        let font = try XCTUnwrap(fixture.view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, 16)
        XCTAssertEqual(CTFontGetMatrix(font).c, 0.2, accuracy: 0.001)
        XCTAssertTrue(fixture.session.source.contains("[font=NotInstalledFont]"))
        XCTAssertGreaterThan(fixture.view.textStorage.attribute(.baselineOffset, at: 2, effectiveRange: nil) as? CGFloat ?? 0, 0)
    }

    func testMediaNeverLoadsImagesAndPasswordPreviewNeverExposesValue() throws {
        for tag in [ForumComposerTag.audio, .media, .flash, .swf] {
            let parameter = tag == .media ? "mp4,640,360" : ""
            let fixture = BBCodeEditorFixture(try ForumComposerSyntax.markup(tag: tag, parameter: parameter, body: "https://example.com/file"))
            let attachment = try XCTUnwrap(fixture.view.textStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? ForumBBCodeAttachment)
            XCTAssertNil(attachment.previewURL)
        }
        let fixture = BBCodeEditorFixture("[password]secret[/password]")
        let attachment = try XCTUnwrap(fixture.view.textStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? ForumBBCodeAttachment)
        let control = ForumBBCodePreviewControl(attachment: attachment)
        XCTAssertFalse(control.accessibilityValue?.contains("secret") ?? true)
    }

    func testTablePanelPreservesShorthandUntilEditedAndMergesRectangle() throws {
        let original = "[TABLE=80%]a|b\nc|d[/TABLE]"
        let model = ForumComposerTablePanelModel(source: original)
        XCTAssertEqual(try model.source(), original)
        let first = try XCTUnwrap(model.table.rows.first?.cells.first?.id)
        let last = try XCTUnwrap(model.table.rows.last?.cells.last?.id)
        model.change { try $0.merge(from: first, through: last) }
        XCTAssertEqual(model.table.rows.first?.cells.first?.columnSpan, 2)
        XCTAssertEqual(model.table.rows.first?.cells.first?.rowSpan, 2)
        XCTAssertTrue(try model.source().contains("[td=2,2]"))
        model.change { try $0.split(id: first) }
        XCTAssertEqual(try model.table.placements().count, 4)
        XCTAssertTrue(try model.source().contains("a\nb\nc\nd"))
    }

    func testPreviewsProducePixelsAtPhoneAndTabletWidths() throws {
        let samples = ["[ruby=るび]注音[/ruby]", "[table][tr][td]a[/td][td]b[/td][/tr][tr][td=2,1]中文[/td][/tr][/table]", "[collapse=1,title][b]body[/b][/collapse]", "[hide=d7,100][i]作者正文[/i][/hide]", "[float=right]右侧内容[/float]"]
        for width: CGFloat in [320, 390, 834] {
            for dark in [false, true] {
                for source in samples {
                    let fixture = BBCodeEditorFixture(source)
                    let span = try XCTUnwrap(fixture.session.projection.spans.first { $0.kind == .atomic })
                    let attachment = try XCTUnwrap(fixture.session.attachment(for: span))
                    let preview = ForumBBCodePreviewControl(attachment: attachment)
                    preview.frame = CGRect(origin: .zero, size: attachment.size(maxWidth: width - 32))
                    preview.traitOverrides.userInterfaceStyle = dark ? .dark : .light
                    preview.setNeedsDisplay(); preview.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: preview.bounds).image { preview.layer.render(in: $0.cgContext) }
                    let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
                    XCTAssertGreaterThan(Set(pixels).count, 16, source)
                    let screenshot = XCTAttachment(image: image)
                    screenshot.name = "bbcode-preview-\(Int(width))-\(dark ? "dark" : "light")-\(attachment.node.tag?.rawValue ?? "node")"
                    screenshot.lifetime = .keepAlways; add(screenshot)
                }
            }
        }
    }
}

@MainActor
private final class BBCodeEditorFixture {
    let session = ForumBBCodeSession()
    let view = ForumBBCodeTextView(usingTextLayoutManager: true)
    let coordinator: ForumBBCodeTextEditor.Coordinator
    init(_ source: String) {
        coordinator = ForumBBCodeTextEditor.Coordinator(text: .constant(source), session: session)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        view.delegate = coordinator
        session.attach(view)
        session.context = .init(target: .init(kind: .newThread), bbcode: .allowed)
        session.load(source, force: true)
    }
}

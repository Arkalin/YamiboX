import CoreText
import SwiftUI
import UIKit
import WebKit
import XCTest
import YamiboXTestSupport
@testable import YamiboXCore
@testable import YamiboXUI

final class ForumComposerPresentationTests: XCTestCase {
    @MainActor
    func testStandaloneFeedbackSheetsRenderEditorsAndSharedToolbar() async throws {
        for width: CGFloat in [320, 834] {
            let comment = await mount(AnyView(ForumThreadCommentSheet(postID: "4001", submit: { _, _ in "ok" })),
                                      size: CGSize(width: width, height: 700))
            let editor = try XCTUnwrap(accessibilityNodes(comment.host.view).compactMap { $0 as? UITextView }.first)
            XCTAssertTrue(accessibilityNodes(comment.host.view).contains { identifier($0) == "forum-composer-send" })
            XCTAssertTrue(editor.isEditable)
            XCTAssertGreaterThan(editor.bounds.height, 100)
            try attach(comment.host.view, name: "shared-comment-\(Int(width))")
            comment.close()

            let rating = await mount(AnyView(ForumThreadRateSheet(postID: "4001", loadOptions: { _ in
                ForumThreadRateOptionsPage(availableScores: [1, 2], defaultReasons: ["Thanks"])
            }, submit: { _, _, _, _ in "ok" })), size: CGSize(width: width, height: 700))
            defer { rating.close() }
            let score = try XCTUnwrap(accessibilityNodes(rating.host.view).compactMap { $0 as? UITextField }.first)
            XCTAssertTrue(accessibilityNodes(rating.host.view).contains { identifier($0) == "forum-composer-send" })
            XCTAssertTrue(score.isEnabled)
            XCTAssertTrue(accessibilityNodes(rating.host.view).contains { $0 is UISwitch })
            try attach(rating.host.view, name: "shared-rating-\(Int(width))")
        }
    }

    @MainActor
    func testItalicChangesRenderedChineseGlyphsInTextKit2() throws {
        let editor = UITextView(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        editor.backgroundColor = .white
        editor.isEditable = false
        editor.traitOverrides.userInterfaceStyle = .light
        XCTAssertNotNil(editor.textLayoutManager)
        let imageFormat = UIGraphicsImageRendererFormat()
        imageFormat.scale = 2
        func render(_ source: String, format: ForumComposerFormat, size: CGFloat) throws -> Data {
            editor.attributedText = ForumRichTextCodec.attributedText(source: source, format: format, theme: .classic, baseFontSize: size)
            editor.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: editor.bounds, format: imageFormat).image {
                editor.layer.render(in: $0.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(Int(size))pt-\(source)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
            XCTAssertGreaterThan(Set(pixels).count, 16)
            return pixels
        }
        for size: CGFloat in [17, 32] {
            for text in ["中文斜体", "Italic", "中文 Italic"] {
                let plain = try render(text, format: .bbcode, size: size)
                for (source, format): (String, ForumComposerFormat) in [
                    ("[i]\(text)[/i]", .bbcode), ("<i>\(text)</i>", .html), ("<em>\(text)</em>", .html)
                ] {
                    XCTAssertNotEqual(try render(source, format: format, size: size), plain, source)
                    let font = try font(in: editor, at: 0)
                    XCTAssertEqual(font.pointSize, size)
                    XCTAssertEqual(CTFontGetMatrix(font).c, 0.2, accuracy: 0.001)
                    XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.traitItalic), "Do not slant a native italic face twice")
                    XCTAssertEqual(ForumComposerMarkup.serialize(ForumRichTextCodec.runs(in: editor.attributedText), format: format), source)
                }
                let bold = try render("[b]\(text)[/b]", format: .bbcode, size: size)
                XCTAssertNotEqual(try render("[b][i]\(text)[/i][/b]", format: .bbcode, size: size), bold)
                XCTAssertTrue(try font(in: editor, at: 0).fontDescriptor.symbolicTraits.contains(.traitBold))
                XCTAssertEqual(try render(text, format: .bbcode, size: size), plain)
            }
        }
    }

    @MainActor
    func testLiveComposerPlainTextSwitchPreservesBBCodeAndHTMLSourceWithoutEditing() async throws {
        let item = try XCTUnwrap(ForumEmoticonCatalog.categories.first?.items.first)
        let samples: [(String, Bool)] = [
            ("[b]你好[/b] [advanced=value]保留[/advanced] \(item.code)", false),
            ("<p><strong>你好</strong> &amp; <custom data-id=\"1\">保留</custom></p>", true)
        ]
        for (source, isBlog) in samples {
            let state = ComposerEditorState(text: source, isHTMLSource: isBlog)
            let pipeline = YamiboUIImagePipeline(core: ComposerOfflineImageBytes(bytes: try fixtureImageData()))
            let fixture = await mount(AnyView(ComposerFullEditorHarness(state: state, isBlog: isBlog)
                .environment(\.yamiboImagePipeline, pipeline)), size: CGSize(width: 390, height: 540))
            defer { fixture.close() }
            let editor = try XCTUnwrap(accessibilityNodes(fixture.host.view).compactMap { $0 as? UITextView }.first)
            let toggle = try XCTUnwrap(accessibilityNodes(fixture.host.view).compactMap { $0 as? UISwitch }.first)
            XCTAssertFalse(accessibilityNodes(fixture.host.view).contains { $0 is UISegmentedControl })
            XCTAssertFalse(toggle.isOn)
            XCTAssertTrue(editor.isEditable)
            XCTAssertTrue(editor.text.contains("你好"))
            XCTAssertFalse(editor.text.contains(isBlog ? "<strong>" : "[b]"))
            XCTAssertTrue(try font(in: editor, at: 0).fontDescriptor.symbolicTraits.contains(.traitBold))
            XCTAssertEqual(state.text, source)

            toggle.setOn(true, animated: false)
            try dispatchValueChanged(toggle)
            await waitFor { editor.text == source }
            XCTAssertEqual(state.text, source)
            XCTAssertEqual(editor.attributedText.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment, nil)
            try attach(fixture.host.view, name: isBlog ? "native-html-code-mode" : "native-bbcode-code-mode")

            toggle.setOn(false, animated: false)
            try dispatchValueChanged(toggle)
            await waitFor { !editor.text.contains(isBlog ? "<strong>" : "[b]") }
            XCTAssertEqual(state.text, source)
            XCTAssertTrue(try font(in: editor, at: 0).fontDescriptor.symbolicTraits.contains(.traitBold))
            XCTAssertTrue(editor.text.contains(isBlog ? "<custom data-id=\"1\">" : "[advanced=value]"))
            try attach(fixture.host.view, name: isBlog ? "native-html-visual-mode" : "native-bbcode-visual-mode")
        }
    }

    @MainActor
    func testPlainTextSwitchFooterFitsNarrowPhoneTabletAndLargeText() async throws {
        let configurations: [(CGFloat, DynamicTypeSize)] = [
            (320, .large), (390, .large), (834, .large), (320, .accessibility3), (390, .accessibility3)
        ]
        for (width, textSize) in configurations {
            let largeText = textSize.isAccessibilitySize
            let state = ComposerEditorState(text: "[b]今天读完最新一章[/b]，很喜欢人物之间的对话。")
            let fixture = await mount(AnyView(ComposerFullEditorHarness(state: state, isBlog: false)
                .environment(\.dynamicTypeSize, textSize)
                .environment(\.colorScheme, largeText ? .dark : .light)),
                size: CGSize(width: width, height: largeText ? 850 : 620))
            defer { fixture.close() }
            fixture.host.traitOverrides.userInterfaceStyle = largeText ? .dark : .light
            fixture.host.view.backgroundColor = .systemBackground
            fixture.host.view.layoutIfNeeded()
            let nodes = accessibilityNodes(fixture.host.view)
            let editor = try XCTUnwrap(nodes.compactMap { $0 as? UITextView }.first)
            let toggle = try XCTUnwrap(nodes.compactMap { $0 as? UISwitch }.first)
            XCTAssertFalse(nodes.contains { $0 is UISegmentedControl })
            XCTAssertFalse(toggle.isOn)
            let editorFrame = editor.convert(editor.bounds, to: fixture.host.view)
            let toggleFrame = toggle.convert(toggle.bounds, to: fixture.host.view)
            XCTAssertGreaterThanOrEqual(toggleFrame.minY, editorFrame.maxY + 44)
            XCTAssertFalse(editorFrame.intersects(toggleFrame))
            XCTAssertGreaterThanOrEqual(toggleFrame.minX, 0)
            XCTAssertLessThanOrEqual(toggleFrame.maxX, fixture.host.view.bounds.maxX)
            XCTAssertLessThanOrEqual(toggleFrame.maxY, fixture.host.view.bounds.maxY)
            XCTAssertGreaterThan(toggleFrame.height, 0)
            try attach(fixture.host.view, name: "native-plain-text-footer-\(Int(width))-\(largeText ? "dark-large" : "standard")")
        }
    }

    @MainActor
    func testMobileComposerRendersOneUploadSectionWithoutGenericFileRows() async throws {
        let page = try ForumFormPageParser.parse(html: ForumMobileComposerFixture.html, url: ForumMobileComposerFixture.url)
        let form = try XCTUnwrap(page.forms.first)
        XCTAssertEqual(page.forms.count, 1)
        XCTAssertNil(page.message)
        XCTAssertEqual(form.kind, .thread)
        XCTAssertEqual(form.fields.map(\.name), ["message"])
        XCTAssertFalse(form.fields.contains { $0.kind == .file || $0.name == "Filedata" })
        XCTAssertEqual(page.uploads.count, 2)
        XCTAssertEqual(page.uploads.filter { $0.kind == .threadImage }.count, 1)
        XCTAssertEqual(page.uploads.filter { $0.kind == .threadAttachment }.count, 1)

        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
            let repository = ComposerPageRepository(page: page)
            let model = ForumPageSession(url: ForumMobileComposerFixture.url, repository: repository)
            let fixture = await mount(AnyView(NavigationStack {
                ForumPageScreen(model: model, onURLTap: { _ in XCTFail("No live navigation") })
                    .forumNavigationBarStyle()
            }.environment(\.dynamicTypeSize, .large).environment(\.colorScheme, .light)), size: size)
            defer { fixture.close() }
            fixture.host.traitOverrides.userInterfaceStyle = .light
            await waitFor { model.page != nil }
            fixture.host.view.layoutIfNeeded()
            let nodes = accessibilityNodes(fixture.host.view)
            let collection = try XCTUnwrap(nodes.compactMap { $0 as? UICollectionView }.first)
            // One body row and one upload row: helper inputs must not create file-picker rows.
            XCTAssertEqual(collection.numberOfSections, 2)
            XCTAssertEqual((0..<collection.numberOfSections).map { collection.numberOfItems(inSection: $0) }, [1, 1])
            XCTAssertFalse(nodes.contains {
                let label = $0.accessibilityLabel ?? ""
                return label.contains("Filedata") || label == L10n.string("forum.native.choose_file")
            })
            let plainTextSwitch = try XCTUnwrap(nodes.compactMap { $0 as? UISwitch }.first)
            XCTAssertFalse(plainTextSwitch.isOn)
            XCTAssertFalse(nodes.contains { $0 is UISegmentedControl })
            try attach(fixture.host.view, name: "native-mobile-composer-upload-section-\(Int(size.width))")
            let counts = await repository.counts
            XCTAssertEqual(counts.loads, 1)
            XCTAssertEqual(counts.submissions, 0)
            XCTAssertEqual(counts.uploads, 0)
        }
    }

    @MainActor
    func testReplyConfirmationDialogPresentsNativeReplyAction() async throws {
        let page = try ForumFormPageParser.parse(html: ForumMobileComposerFixture.html, url: ForumMobileComposerFixture.url)
        let form = try XCTUnwrap(page.forms.first)
        let field = try XCTUnwrap(form.fields.first { $0.name == "message" })
        let button = try XCTUnwrap(form.buttons.first)
        let repository = ComposerConfirmedReplyRepository(page: page)
        let model = ForumPageSession(url: ForumMobileComposerFixture.url, repository: repository)
        let fixture = await mount(AnyView(NavigationStack {
            ForumPageScreen(model: model, onURLTap: { _ in XCTFail("No live navigation") })
                .forumNavigationBarStyle()
        }), size: CGSize(width: 390, height: 844))
        defer { fixture.close() }
        await waitFor { model.page != nil }
        let editor = try XCTUnwrap(accessibilityNodes(fixture.host.view).compactMap { $0 as? UITextView }.first)
        editor.becomeFirstResponder()
        editor.insertText("离线回复确认测试")
        await waitFor { model.drafts[form.id]?[field.id] == ["离线回复确认测试"] }
        editor.resignFirstResponder()

        // Preparing the dialog is setup; no submission is authorized before confirmation.
        model.prepareSubmission(form: form, button: button)
        XCTAssertNotNil(model.pendingSubmission)
        let deadline = ContinuousClock.now + .seconds(2)
        while presentedAlert(in: fixture.host) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try attach(fixture.host.view, name: "native-reply-confirmation-presenter")
        let alert = try XCTUnwrap(presentedAlert(in: fixture.host))
        alert.view.layoutIfNeeded()
        try attach(alert.view, name: "native-reply-confirmation-dialog")
        XCTAssertEqual(alert.actions.filter { $0.title == button.title }.count, 1)
        let before = await repository.submissionValues.count
        XCTAssertEqual(before, 0)
        let label = accessibilityNodes(alert.view).compactMap { $0 as? UILabel }.first { $0.text == button.title }
        var candidate = findElement("native-reply-confirm-action", label: button.title, in: alert.view) ?? label
        var activated = false
        while let action = candidate {
            if action.accessibilityActivate() { activated = true; break }
            candidate = (action as? UIView)?.superview
        }
        if !activated {
            let capability = XCTAttachment(string: "System confirmation dialog and reply action rendered. Public accessibility activation is unavailable in this host; no system tap or submission was simulated. Confirmation dismissal and submission are covered by the view-model regressions.")
            capability.name = "native-reply-confirmation-interaction-limit"
            capability.lifetime = .keepAlways
            add(capability)
            let unchanged = await repository.submissionValues.count
            XCTAssertEqual(unchanged, 0)
            XCTAssertNotNil(model.pendingSubmission)
            return
        }
        let submissionDeadline = ContinuousClock.now + .seconds(3)
        while await repository.submissionValues.isEmpty, ContinuousClock.now < submissionDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let submitted = await repository.submissionValues
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first?[field.id], ["离线回复确认测试"])
        XCTAssertNil(model.pendingSubmission)
    }

    @MainActor
    private func presentedAlert(in controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController, let alert = presentedAlert(in: presented) { return alert }
        return controller.children.compactMap { presentedAlert(in: $0) }.first
    }

    @MainActor
    func testHTMLStrongAndEmphasisToggleOffAndUndoRestoresOriginalTags() async throws {
        let cases: [(String, String, String, UIFontDescriptor.SymbolicTraits)] = [
            ("<strong>粗体</strong>", "粗体", "b", .traitBold),
            ("<em>斜体</em>", "斜体", "i", .traitItalic),
            ("<strong><b>双重粗体</b></strong>", "双重粗体", "b", .traitBold),
            ("<em><i>双重斜体</i></em>", "双重斜体", "i", .traitItalic)
        ]
        for (source, plainText, tag, trait) in cases {
            let state = ComposerEditorState(text: source, isHTMLSource: true)
            let controller = ForumEditorController()
            let fixture = await mount(AnyView(ComposerTextEditorHarness(state: state, controller: controller, isBlog: true)), size: CGSize(width: 390, height: 480))
            defer { fixture.close() }
            let editor = try XCTUnwrap(controller.view)
            XCTAssertEqual(editor.text, plainText)
            XCTAssertTrue(try hasFontTrait(trait, in: editor))
            editor.becomeFirstResponder()
            editor.selectedRange = NSRange(location: 0, length: plainText.utf16.count)
            try await Task.sleep(for: .milliseconds(100))
            editor.undoManager?.beginUndoGrouping()
            controller.wrap(before: "<\(tag)>", after: "</\(tag)>", placeholder: "", encodeHTML: false)
            editor.undoManager?.endUndoGrouping()
            XCTAssertEqual(editor.text, plainText)
            XCTAssertEqual(state.text, plainText)
            XCTAssertFalse(try hasFontTrait(trait, in: editor))

            controller.undo()
            XCTAssertEqual(state.text, source)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: plainText.utf16.count))
            XCTAssertTrue(try hasFontTrait(trait, in: editor))
            if source == "<strong>粗体</strong>" {
                editor.selectedRange = NSRange(location: 1, length: 0)
                controller.wrap(before: "<b>", after: "</b>", placeholder: "", encodeHTML: false)
                editor.insertText("新")
                XCTAssertEqual(state.text, "<strong>粗</strong>新<strong>体</strong>")
                XCTAssertFalse(try font(in: editor, at: 1).fontDescriptor.symbolicTraits.contains(.traitBold))
            }
        }

        let source = "<strong><em>Body</em></strong>"
        let state = ComposerEditorState(text: source, isHTMLSource: true)
        let controller = ForumEditorController()
        let fixture = await mount(AnyView(ComposerTextEditorHarness(state: state, controller: controller, isBlog: true)), size: CGSize(width: 390, height: 480))
        defer { fixture.close() }
        let editor = try XCTUnwrap(controller.view)
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: 0, length: 4)
        editor.undoManager?.beginUndoGrouping()
        controller.wrap(before: "<b>", after: "</b>", placeholder: "", encodeHTML: false)
        editor.undoManager?.endUndoGrouping()
        XCTAssertEqual(state.text, "<em>Body</em>")
        XCTAssertFalse(try font(in: editor, at: 0).fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(try hasFontTrait(.traitItalic, in: editor))
        controller.undo()
        XCTAssertEqual(state.text, source)
    }

    @MainActor
    func testPageSubmissionPreparationCommitsMarkedTextThroughRegisteredEditor() async throws {
        let page = try ForumFormPageParser.parse(html: ForumMobileComposerFixture.html, url: ForumMobileComposerFixture.url)
        let form = try XCTUnwrap(page.forms.first)
        let field = try XCTUnwrap(form.fields.first { $0.name == "message" })
        let button = try XCTUnwrap(form.buttons.first)
        for codeMode in [false, true] {
            let repository = ComposerPageRepository(page: page)
            let model = ForumPageSession(url: ForumMobileComposerFixture.url, repository: repository)
            let registry = ForumEditorRegistry()
            let fixture = await mount(AnyView(NavigationStack {
                ForumPageScreen(model: model, editorRegistry: registry, onURLTap: { _ in XCTFail("No live navigation") })
                    .forumNavigationBarStyle()
            }), size: CGSize(width: 390, height: 844))
            defer { fixture.close() }
            await waitFor { model.page != nil }
            let nodes = accessibilityNodes(fixture.host.view)
            let editor = try XCTUnwrap(nodes.compactMap { $0 as? UITextView }.first)
            let controller = registry.controller(for: field.id)
            XCTAssertTrue(controller.view === editor)
            if codeMode {
                let toggle = try XCTUnwrap(nodes.compactMap { $0 as? UISwitch }.first)
                toggle.setOn(true, animated: false)
                try dispatchValueChanged(toggle)
                await waitFor { !controller.isVisual }
            }
            editor.becomeFirstResponder()
            editor.insertText("前\u{1F642}")
            await waitFor { model.drafts[form.id]?[field.id] == ["前\u{1F642}"] }
            editor.setMarkedText("组词", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(editor.markedTextRange)
            XCTAssertEqual(editor.text, "前\u{1F642}组词")
            XCTAssertEqual(model.drafts[form.id]?[field.id], ["前\u{1F642}"])
            XCTAssertNil(model.pendingSubmission)

            // Invoke the same preparation path used by the page, without committing IME in the test.
            registry.prepareSubmission(form: form, button: button, model: model)
            XCTAssertNil(editor.markedTextRange)
            XCTAssertEqual(model.drafts[form.id]?[field.id], ["前\u{1F642}组词"])
            XCTAssertEqual(model.pendingSubmission?.values[field.id], ["前\u{1F642}组词"])
            let counts = await repository.counts
            XCTAssertEqual(counts.loads, 1)
            XCTAssertEqual(counts.submissions, 0)
            XCTAssertEqual(counts.uploads, 0)
        }
    }

    @MainActor
    func testLiveRichTextTypingFormattingAndUndoUpdateBoundSource() async throws {
        let state = ComposerEditorState(text: "[b]你好[/b]尾")
        let controller = ForumEditorController()
        let fixture = await mount(AnyView(ComposerTextEditorHarness(state: state, controller: controller)), size: CGSize(width: 390, height: 480))
        defer { fixture.close() }
        let editor = try XCTUnwrap(controller.view)
        XCTAssertTrue(controller.isVisual)
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: 1, length: 0)
        editor.insertText("新")
        await waitFor { state.text == "[b]你新好[/b]尾" }
        XCTAssertEqual(state.text, "[b]你新好[/b]尾")
        XCTAssertEqual(editor.text, "你新好尾")
        XCTAssertTrue(try font(in: editor, at: 1).fontDescriptor.symbolicTraits.contains(.traitBold))
        // Separate typing and toolbar actions into their normal event-loop undo groups.
        try await Task.sleep(for: .milliseconds(100))

        editor.selectedRange = NSRange(location: 3, length: 1)
        editor.undoManager?.beginUndoGrouping()
        controller.wrap(before: "[u]", after: "[/u]", placeholder: "", encodeHTML: false)
        editor.undoManager?.endUndoGrouping()
        await waitFor { state.text == "[b]你新好[/b][u]尾[/u]" }
        XCTAssertEqual(state.text, "[b]你新好[/b][u]尾[/u]")
        XCTAssertEqual(editor.attributedText.attribute(.underlineStyle, at: 3, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        controller.undo()
        await waitFor { state.text == "[b]你新好[/b]尾" }
        XCTAssertEqual(state.text, "[b]你新好[/b]尾")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 3, length: 1))
        XCTAssertNil(editor.attributedText.attribute(.underlineStyle, at: 3, effectiveRange: nil))

        editor.selectedRange = NSRange(location: 1, length: 0)
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertEqual(state.text, "[b]你新好[/b]尾")
        controller.pauseEditing()
        XCTAssertNil(editor.markedTextRange)
        await waitFor { state.text == "[b]你中文新好[/b]尾" }
        XCTAssertEqual(state.text, "[b]你中文新好[/b]尾")
        XCTAssertTrue(try font(in: editor, at: 1).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @MainActor
    func testLiveRichTextIMEAndPausedEmoticonBecomeImageThenExactCode() async throws {
        let item = try XCTUnwrap(ForumEmoticonCatalog.categories.first?.items.first)
        let state = ComposerEditorState(text: "A\u{1F642}尾")
        let controller = ForumEditorController()
        let imageBytes = try fixtureImageData()
        let pipeline = YamiboUIImagePipeline(core: ComposerOfflineImageBytes(bytes: imageBytes))
        let fixture = await mount(AnyView(ComposerTextEditorHarness(state: state, controller: controller)
            .environment(\.yamiboImagePipeline, pipeline)), size: CGSize(width: 390, height: 480))
        defer { fixture.close() }
        let editor = try XCTUnwrap(controller.view)
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: 3, length: 0)
        editor.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertEqual(state.text, "A\u{1F642}尾")
        controller.pauseEditing()
        XCTAssertNil(editor.markedTextRange)
        await waitFor { state.text == "A\u{1F642}你好尾" }
        editor.selectedRange = NSRange(location: 0, length: 0)
        controller.insertEmoticon(item, isBlog: false, encodeHTML: false)
        let expected = "A\u{1F642}你好\(item.code)尾"
        await waitFor { state.text == expected }
        XCTAssertEqual(editor.text, "A\u{1F642}你好\u{FFFC}尾")
        let attachment = try XCTUnwrap(editor.attributedText.attribute(.attachment, at: 5, effectiveRange: nil) as? ForumComposerImageAttachment)
        XCTAssertEqual(attachment.imageURL, item.imageURL)
        await waitFor { pipeline.cachedImage(for: YamiboImageSource(url: item.imageURL, refererPageURL: YamiboDomain.baseURL)) != nil }
        XCTAssertFalse(editor.text.contains(item.code))
        try attach(fixture.host.view, name: "native-rich-emoticon-attachment")

        state.mode = .code
        await waitFor { editor.text == expected && !controller.isVisual }
        state.mode = .visual
        await waitFor { controller.isVisual && editor.text.contains("\u{FFFC}") }
        XCTAssertEqual(state.text, expected)
        XCTAssertEqual((editor.attributedText.attribute(.attachment, at: 5, effectiveRange: nil) as? ForumComposerImageAttachment)?.imageURL, item.imageURL)

        editor.selectedRange = NSRange(location: 6, length: 0)
        editor.insertText("续")
        await waitFor { state.text == "A\u{1F642}你好\(item.code)续尾" }
        XCTAssertEqual(state.text, "A\u{1F642}你好\(item.code)续尾")
        XCTAssertFalse(state.text.contains("\u{FFFC}"))
        editor.selectedRange = NSRange(location: 3, length: 0)
        editor.insertText("中")
        await waitFor { state.text == "A\u{1F642}中你好\(item.code)续尾" }
        XCTAssertEqual(state.text, "A\u{1F642}中你好\(item.code)续尾")
        XCTAssertFalse(state.text.contains("\u{FFFC}"))
    }

    @MainActor
    func testBlogEmptySelectionFormattingDoesNotConvertUntouchedPlainTextBeforeSubmission() async throws {
        let state = ComposerEditorState(text: "<草稿>&\n正文")
        let controller = ForumEditorController()
        let fixture = await mount(AnyView(ComposerTextEditorHarness(state: state, controller: controller, isBlog: true)), size: CGSize(width: 390, height: 480))
        defer { fixture.close() }
        let editor = try XCTUnwrap(controller.view)
        editor.selectedRange = NSRange(location: 0, length: 0)
        controller.wrap(before: "<b>", after: "</b>", placeholder: "", encodeHTML: true)
        XCTAssertEqual(editor.text, "<草稿>&\n正文")
        XCTAssertEqual(state.text, "<草稿>&\n正文")
        XCTAssertFalse(state.isHTMLSource)

        let url = URL(string: "https://bbs.yamibo.com/home.php?mod=spacecp&ac=blog")!
        let page = try ForumFormPageParser.parse(html: """
        <div id="ct"><form method="post" action="home.php?mod=spacecp&amp;ac=blog">
        <input name="subject" value="草稿"><textarea name="message"></textarea>
        <button type="submit" name="blogsubmit" value="true">发布</button></form></div>
        """, url: url)
        let form = try XCTUnwrap(page.forms.first)
        XCTAssertEqual(form.kind, .blog)
        let field = try XCTUnwrap(form.fields.first { $0.name == "message" })
        let button = try XCTUnwrap(form.buttons.first)
        let repository = ComposerPageRepository(page: page)
        let model = ForumPageSession(url: url, repository: repository)
        await model.load()
        model.drafts[form.id]?[field.id] = [state.text]
        if state.isHTMLSource { model.htmlSourceFields.insert(field.id) }
        model.prepareSubmission(form: form, button: button)
        XCTAssertEqual(model.pendingSubmission?.values[field.id], ["&lt;草稿&gt;&amp;<br>正文"])

        editor.selectedRange = NSRange(location: 0, length: editor.text.utf16.count)
        editor.undoManager?.beginUndoGrouping()
        controller.wrap(before: "<b>", after: "</b>", placeholder: "", encodeHTML: true)
        editor.undoManager?.endUndoGrouping()
        XCTAssertTrue(state.isHTMLSource)
        controller.undo()
        XCTAssertEqual(editor.text, "<草稿>&\n正文")
        XCTAssertEqual(state.text, "&lt;草稿&gt;&amp;<br>正文")
        model.drafts[form.id]?[field.id] = [state.text]
        if state.isHTMLSource { model.htmlSourceFields.insert(field.id) }
        model.prepareSubmission(form: form, button: button)
        XCTAssertEqual(model.pendingSubmission?.values[field.id], ["&lt;草稿&gt;&amp;<br>正文"])
        let counts = await repository.counts
        XCTAssertEqual(counts.submissions, 0)
    }

    @MainActor
    func testModeSwitchClampsCaretBeforeEmojiAndContinuedTypingKeepsMarkup() async throws {
        let state = ComposerEditorState(text: "[b]你\u{1F642}[/b]")
        state.mode = .code
        let controller = ForumEditorController()
        let fixture = await mount(AnyView(ComposerTextEditorHarness(state: state, controller: controller)), size: CGSize(width: 390, height: 480))
        defer { fixture.close() }
        let editor = try XCTUnwrap(controller.view)
        editor.selectedRange = NSRange(location: 2, length: 0)
        state.mode = .visual
        await waitFor { controller.isVisual && editor.text == "你\u{1F642}" }
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertNotNil(Range(editor.selectedRange, in: editor.text))
        editor.becomeFirstResponder()
        editor.insertText("中")
        await waitFor { state.text == "[b]你中\u{1F642}[/b]" }
        XCTAssertEqual(state.text, "[b]你中\u{1F642}[/b]")
        XCTAssertEqual(editor.text, "你中\u{1F642}")
    }

    @MainActor
    func testEmptyVisualEditorBoldTypingProducesFormattedSource() async throws {
        let state = ComposerEditorState(text: "")
        let controller = ForumEditorController()
        let fixture = await mount(AnyView(ComposerTextEditorHarness(state: state, controller: controller)), size: CGSize(width: 390, height: 480))
        defer { fixture.close() }
        let editor = try XCTUnwrap(controller.view)
        controller.wrap(before: "[b]", after: "[/b]", placeholder: "", encodeHTML: false)
        XCTAssertEqual(state.text, "")
        editor.insertText("正文")
        await waitFor { state.text == "[b]正文[/b]" }
        XCTAssertEqual(state.text, "[b]正文[/b]")
        XCTAssertEqual(editor.text, "正文")
        XCTAssertTrue(try font(in: editor, at: 0).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @MainActor
    func testChineseItalicTypingToggleUndoAndCodeModePreserveMarkup() async throws {
        for isBlog in [false, true] {
            let state = ComposerEditorState(text: "", isHTMLSource: isBlog)
            let controller = ForumEditorController()
            let fixture = await mount(AnyView(ComposerTextEditorHarness(state: state, controller: controller, isBlog: isBlog)), size: CGSize(width: 390, height: 480))
            defer { fixture.close() }
            let editor = try XCTUnwrap(controller.view)
            XCTAssertNotNil(editor.textLayoutManager)
            let opening = isBlog ? "<i>" : "[i]"
            let closing = isBlog ? "</i>" : "[/i]"
            controller.wrap(before: opening, after: closing, placeholder: "", encodeHTML: false)
            editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(editor.markedTextRange)
            XCTAssertEqual(state.text, "")
            controller.pauseEditing()
            controller.cancelPausedEditing()
            let source = opening + "中文" + closing
            XCTAssertNil(editor.markedTextRange)
            XCTAssertEqual(state.text, source)
            XCTAssertTrue(try hasFontTrait(.traitItalic, in: editor))
            try await Task.sleep(for: .milliseconds(100))

            editor.selectedRange = NSRange(location: 0, length: 2)
            editor.undoManager?.beginUndoGrouping()
            controller.wrap(before: opening, after: closing, placeholder: "", encodeHTML: false)
            editor.undoManager?.endUndoGrouping()
            XCTAssertEqual(state.text, "中文")
            XCTAssertFalse(try hasFontTrait(.traitItalic, in: editor))
            controller.undo()
            XCTAssertEqual(state.text, source)
            XCTAssertTrue(try hasFontTrait(.traitItalic, in: editor))

            editor.resignFirstResponder()
            state.mode = .code
            await waitFor { !controller.isVisual && editor.text == source }
            XCTAssertFalse(try hasFontTrait(.traitItalic, in: editor))
            state.mode = .visual
            await waitFor { controller.isVisual && editor.text == "中文" }
            XCTAssertEqual(state.text, source)
            XCTAssertTrue(try hasFontTrait(.traitItalic, in: editor))
            try attach(fixture.host.view, name: isBlog ? "chinese-italic-html-editor" : "chinese-italic-bbcode-editor")
        }
    }

    @MainActor
    private func hasFontTrait(_ trait: UIFontDescriptor.SymbolicTraits, in editor: UITextView) throws -> Bool {
        let font = try font(in: editor, at: 0)
        if trait == .traitItalic { return CTFontGetMatrix(font).c > 0 }
        return font.fontDescriptor.symbolicTraits.contains(trait)
    }

    @MainActor
    private func font(in editor: UITextView, at index: Int) throws -> UIFont {
        try XCTUnwrap(editor.attributedText.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
    }

    @MainActor
    private func dispatchValueChanged(_ control: UIControl) throws {
        // A logic-test process has no UIApplicationMain to route sendActions.
        var actionCount = 0
        for target in control.allTargets {
            guard let object = target as? NSObject else { continue }
            for action in control.actions(forTarget: object, forControlEvent: .valueChanged) ?? [] {
                let selector = NSSelectorFromString(action)
                switch action.filter({ $0 == ":" }).count {
                case 0: object.perform(selector)
                case 1: object.perform(selector, with: control)
                default: object.perform(selector, with: control, with: nil)
                }
                actionCount += 1
            }
        }
        XCTAssertGreaterThan(actionCount, 0, "Expected a registered value-changed action")
    }

    @MainActor
    func testEmoticonRestoresPausedUTF16CursorAndUndoRestoresSelection() throws {
        let item = try XCTUnwrap(ForumEmoticonCatalog.categories.first?.items.first)
        let source = "A\u{1F642}BC"
        let editor = ComposerUndoTextView()
        editor.text = source
        editor.selectedRange = NSRange(location: 3, length: 0)
        let recorder = ComposerTextRecorder()
        editor.delegate = recorder
        let controller = ForumEditorController()
        controller.view = editor

        controller.pauseEditing()
        editor.selectedRange = NSRange(location: source.utf16.count, length: 0)
        editor.fixtureUndoManager.beginUndoGrouping()
        controller.insertEmoticon(item, isBlog: false, encodeHTML: false)
        editor.fixtureUndoManager.endUndoGrouping()
        XCTAssertEqual(editor.text, "A\u{1F642}\(item.code)BC")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 3 + item.code.utf16.count, length: 0))
        XCTAssertEqual(recorder.text, editor.text)

        controller.undo()
        XCTAssertEqual(editor.text, source)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertEqual(recorder.text, source)
    }

    @MainActor
    func testEmoticonReplacesSelectionAndCancelledPickerDoesNotReuseOldCursor() throws {
        let item = try XCTUnwrap(ForumEmoticonCatalog.categories.first?.items.first)
        let editor = ComposerUndoTextView()
        editor.text = "A\u{1F642}BC"
        editor.selectedRange = NSRange(location: 1, length: 2)
        let controller = ForumEditorController()
        controller.view = editor
        editor.fixtureUndoManager.beginUndoGrouping()
        controller.insertEmoticon(item, isBlog: false, encodeHTML: false)
        editor.fixtureUndoManager.endUndoGrouping()
        XCTAssertEqual(editor.text, "A\(item.code)BC")
        controller.undo()
        XCTAssertEqual(editor.text, "A\u{1F642}BC")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 2))

        editor.selectedRange = NSRange(location: 0, length: 0)
        controller.pauseEditing()
        controller.cancelPausedEditing()
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        editor.fixtureUndoManager.beginUndoGrouping()
        controller.insertEmoticon(item, isBlog: false, encodeHTML: false)
        editor.fixtureUndoManager.endUndoGrouping()
        XCTAssertEqual(editor.text, "A\u{1F642}BC\(item.code)")
    }

    @MainActor
    func testBlogEmoticonUsesImageMarkupAndEncodesPlainTextOnlyOnce() throws {
        let item = try XCTUnwrap(ForumEmoticonCatalog.categories.first?.items.first)
        let editor = ComposerUndoTextView()
        editor.text = "<draft>&\n"
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        let controller = ForumEditorController()
        controller.view = editor
        editor.fixtureUndoManager.beginUndoGrouping()
        controller.insertEmoticon(item, isBlog: true, encodeHTML: true)
        editor.fixtureUndoManager.endUndoGrouping()
        let markup = "<img src=\"\(item.imageURL.absoluteString)\" alt=\"\(item.code)\">"
        XCTAssertEqual(editor.text, "&lt;draft&gt;&amp;<br>" + markup)
        editor.fixtureUndoManager.beginUndoGrouping()
        controller.insertEmoticon(item, isBlog: true, encodeHTML: false)
        editor.fixtureUndoManager.endUndoGrouping()
        XCTAssertEqual(editor.text, "&lt;draft&gt;&amp;<br>" + markup + markup)
    }

    @MainActor
    func testPauseEditingCommitsMarkedTextBeforeSavingFinalCursor() throws {
        let item = try XCTUnwrap(ForumEmoticonCatalog.categories.first?.items.first)
        let editor = ComposerMarkedTextView()
        editor.text = "A"
        editor.selectedRange = NSRange(location: 1, length: 0)
        editor.setMarkedText("candidate", selectedRange: NSRange(location: 9, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        let recorder = ComposerTextRecorder()
        editor.delegate = recorder
        let controller = ForumEditorController()
        controller.view = editor
        controller.pauseEditing()
        XCTAssertNil(editor.markedTextRange)
        XCTAssertEqual(editor.text, "A\u{4F60}\u{597D}")
        XCTAssertEqual(recorder.text, editor.text)
        editor.selectedRange = NSRange(location: 0, length: 0)
        editor.fixtureUndoManager.beginUndoGrouping()
        controller.insertEmoticon(item, isBlog: false, encodeHTML: false)
        editor.fixtureUndoManager.endUndoGrouping()
        XCTAssertEqual(editor.text, "A\u{4F60}\u{597D}\(item.code)")
    }

    @MainActor
    func testOfflineNativeEmoticonGridRendersCachedImagesOnPhoneAndTablet() async throws {
        let original = try XCTUnwrap(ForumEmoticonCatalog.categories.first)
        let category = ForumEmoticonCategory(id: original.id, name: original.name, items: Array(original.items.prefix(8)))
        XCTAssertEqual(category.items.count, 8)
        for size in [CGSize(width: 390, height: 600), CGSize(width: 834, height: 700)] {
            let imageBytes = try fixtureImageData()
            let pipeline = YamiboUIImagePipeline(core: ComposerOfflineImageBytes(bytes: imageBytes))
            let picker = ForumEmoticonPicker(categories: [category]) { _ in }
                .environment(\.yamiboImagePipeline, pipeline)
            let fixture = await mount(AnyView(picker), size: size)
            defer { fixture.close() }
            await waitFor {
                category.items.allSatisfy { pipeline.cachedImage(for: YamiboImageSource(url: $0.imageURL, refererPageURL: YamiboDomain.baseURL)) != nil }
            }
            try await Task.sleep(for: .milliseconds(150))
            fixture.host.view.layoutIfNeeded()
            try attach(fixture.host.view, name: "native-emoticon-grid-\(Int(size.width))")
        }
    }

    @MainActor
    func testParsedComposerLocalizesAttachmentsRendersAndPreparesWithoutSubmitting() async throws {
        let page = try ForumFormPageParser.parse(html: Self.composerHTML, url: Self.postURL)
        XCTAssertEqual(page.forms.count, 1)
        let form = try XCTUnwrap(page.forms.first)
        XCTAssertEqual(page.uploads.count, 2)
        XCTAssertFalse(form.fields.contains { $0.name == "Filedata" })
        XCTAssertFalse(form.fields.contains { $0.label.contains("Filedata") })
        let signatureField = try XCTUnwrap(form.fields.first { $0.name == "usesig" })
        XCTAssertEqual(signatureField.label, L10n.string("forum.native.use_signature"))
        XCTAssertEqual(signatureField.initialValues, ["1"])
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1194)] {
            let repository = ComposerPageRepository(page: page)
            let model = ForumPageSession(url: Self.postURL, repository: repository)
            let fixture = await mount(AnyView(NavigationStack {
                ForumPageScreen(model: model, onURLTap: { _ in XCTFail("No live navigation") })
                    .forumNavigationBarStyle()
            }), size: size)
            defer { fixture.close() }
            await waitFor { model.page != nil }
            fixture.host.view.layoutIfNeeded()
            try attach(fixture.host.view, name: "native-composer-polished-\(Int(size.width))")
            XCTAssertFalse(accessibilityNodes(fixture.host.view).contains { ($0.accessibilityLabel ?? "").contains("Filedata") })
            let collection = try XCTUnwrap(accessibilityNodes(fixture.host.view).compactMap { $0 as? UICollectionView }.first)
            let lastSection = try XCTUnwrap((0..<collection.numberOfSections).last { collection.numberOfItems(inSection: $0) > 0 })
            let optionsPath = IndexPath(item: collection.numberOfItems(inSection: lastSection) - 1, section: lastSection)
            collection.scrollToItem(at: optionsPath, at: .bottom, animated: false)
            try await Task.sleep(for: .milliseconds(150))
            fixture.host.view.layoutIfNeeded()
            try attach(fixture.host.view, name: "native-composer-options-collapsed-\(Int(size.width))")
            // Scene-less hosting can render SwiftUI controls without exposing their AX actions.
            // Real disclosure/toggle interaction is covered by ForumComposerOptionsInteractionTests.
            let button = try XCTUnwrap(form.buttons.first)
            // The logic-test host does not expose navigation bar buttons to accessibility.
            model.prepareSubmission(form: form, button: button)
            XCTAssertNotNil(model.pendingSubmission)
            XCTAssertEqual(model.pendingSubmission?.values[signatureField.id], ["1"])
            model.pendingSubmission = nil
            let counts = await repository.counts
            XCTAssertEqual(counts.loads, 1)
            XCTAssertEqual(counts.submissions, 0)
            XCTAssertEqual(counts.uploads, 0)
            if size.width == 390 {
                fixture.host.traitOverrides.userInterfaceStyle = .dark
                fixture.host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
                fixture.host.rootView = AnyView(NavigationStack {
                    ForumPageScreen(model: model, onURLTap: { _ in XCTFail("No live navigation") })
                        .forumNavigationBarStyle()
                }.environment(\.dynamicTypeSize, .accessibility3).environment(\.colorScheme, .dark))
                try await Task.sleep(for: .milliseconds(200))
                fixture.host.view.layoutIfNeeded()
                let largeTextEditor = try XCTUnwrap(accessibilityNodes(fixture.host.view).compactMap { $0 as? UITextView }.first)
                XCTAssertGreaterThan(try font(in: largeTextEditor, at: 0).pointSize, 24)
                try attach(fixture.host.view, name: "native-composer-dark-large-text")
            }
        }
    }

    func testLegitimateFileInputStillHasChineseLabel() throws {
        let page = try ForumFormPageParser.parse(html: """
        <div id="ct"><form method="post" action="home.php?mod=spacecp&amp;ac=profile">
        <input type="file" name="Filedata"><button type="submit">Confirm</button>
        </form></div>
        """, url: Self.postURL)
        let field = try XCTUnwrap(page.forms.first?.fields.first)
        XCTAssertEqual(field.label, L10n.string("forum.native.attachments"))
        XCTAssertNotEqual(field.label, "Filedata")
    }

    @MainActor
    private func mount(_ view: AnyView, size: CGSize) async -> ComposerWindowFixture {
        let host = UIHostingController(rootView: AnyView(view.environment(\.horizontalSizeClass, size.width > 600 ? .regular : .compact)))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKey = scene?.keyWindow
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        host.traitOverrides.horizontalSizeClass = size.width > 600 ? .regular : .compact
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        return ComposerWindowFixture(window: window, host: host, previousKey: previousKey)
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Expected native UI transition did not occur", file: file, line: line)
    }

    @MainActor
    private func findElement(_ id: String, label: String? = nil, in view: UIView) -> NSObject? {
        let nodes = accessibilityNodes(view)
        let matchingLabels = nodes.filter { label != nil && $0.accessibilityLabel == label }
        return nodes.first { identifier($0) == id }
                ?? matchingLabels.first { $0.accessibilityTraits.contains(.button) }
                ?? matchingLabels.first { $0.isAccessibilityElement }
                ?? matchingLabels.first
    }

    @MainActor
    private func identifier(_ node: NSObject) -> String? {
        guard node.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return node.value(forKey: "accessibilityIdentifier") as? String
    }

    @MainActor
    private func accessibilityNodes(_ root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = ((node.automationElements ?? []) + (node.accessibilityElements ?? [])).compactMap { $0 as? NSObject }
            let count = node.accessibilityElementCount()
            if count > 0 && count < 1000 {
                children += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = node as? UIView { children += view.subviews }
            return [node] + children.flatMap(visit)
        }
        return visit(root)
    }

    @MainActor
    private func attach(_ view: UIView, name: String) throws {
        let nodes = accessibilityNodes(view)
        XCTAssertFalse(nodes.contains { $0 is WKWebView })
        let hierarchy = XCTAttachment(string: nodes.map {
            "\(type(of: $0)) id=\(identifier($0) ?? "") label=\($0.accessibilityLabel ?? "") traits=\($0.accessibilityTraits.rawValue) frame=\($0.accessibilityFrame)"
        }.joined(separator: "\n"))
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { view.layer.render(in: $0.cgContext) }
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 16)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func fixtureImageData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 4, y: 4, width: 40, height: 40))
            UIColor.white.setFill()
            context.fill(CGRect(x: 12, y: 14, width: 6, height: 6))
            context.fill(CGRect(x: 30, y: 14, width: 6, height: 6))
            context.fill(CGRect(x: 14, y: 30, width: 20, height: 4))
        }
        return try XCTUnwrap(image.pngData())
    }

    private static let postURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=21")!
    private static let composerHTML = """
    <html><head><title>发布新帖</title></head><body><div id="ct">
    <script>
    var images = new SWFUpload({upload_url: 'misc.php?mod=swfupload&operation=upload',
    post_params: {"uid":"fixture-user","hash":"fixture-hash","type":"image"},
    uploadSource: 'forum', uploadType: 'image', file_size_limit: "2048", file_types: "*.jpg;*.png"});
    var attachments = new SWFUpload({upload_url: 'misc.php?mod=swfupload&operation=upload',
    post_params: {"uid":"fixture-user","hash":"fixture-hash","type":"attach"},
    uploadSource: 'forum', uploadType: 'attach', file_size_limit: "2048", file_types: "*.zip;*.txt"});
    </script>
    <form id="postform" method="post" action="forum.php?mod=post&amp;action=newthread&amp;fid=21">
      <input type="hidden" name="formhash" value="synthetic-token">
      <input name="subject" value="读完这一章，想和大家聊聊">
      <textarea name="message">今天读完了最新一章，很喜欢人物之间的对话。
    想听听大家最喜欢哪一段，也欢迎分享自己的理解。</textarea>
      <select name="typeid"><option value="1" selected>交流讨论</option></select>
      <input type="checkbox" name="usesig" value="1" checked>
      <input name="tags" value="阅读感想">
      <button type="submit" name="topicsubmit" value="yes">发布</button>
    </form>
    <div id="e_menus"><form id="imgattachform" method="post" action="misc.php?mod=swfupload">
      <input type="file" name="Filedata"><button type="submit">Upload helper</button>
    </form></div>
    </div></body></html>
    """
}

@MainActor
private final class ComposerEditorState: ObservableObject {
    @Published var text: String
    @Published var isHTMLSource: Bool
    @Published var mode = ForumComposerMode.visual

    init(text: String, isHTMLSource: Bool = false) {
        self.text = text
        self.isHTMLSource = isHTMLSource
    }
}

private struct ComposerFullEditorHarness: View {
    @ObservedObject var state: ComposerEditorState
    let isBlog: Bool

    var body: some View {
        ForumComposerEditor(text: $state.text, isBlog: isBlog, isHTMLSource: $state.isHTMLSource)
            .padding()
    }
}

private struct ComposerTextEditorHarness: View {
    @ObservedObject var state: ComposerEditorState
    let controller: ForumEditorController
    var isBlog = false

    var body: some View {
        ForumTextEditor(text: $state.text, isHTMLSource: $state.isHTMLSource, isBlog: isBlog, mode: state.mode, controller: controller)
            .padding()
    }
}

@MainActor
private class ComposerUndoTextView: UITextView {
    let fixtureUndoManager = UndoManager()
    override var undoManager: UndoManager? { fixtureUndoManager }
}

@MainActor
private final class ComposerMarkedTextView: ComposerUndoTextView {
    override func unmarkText() {
        guard let marked = markedTextRange else { super.unmarkText(); return }
        let range = NSRange(location: offset(from: beginningOfDocument, to: marked.start), length: offset(from: marked.start, to: marked.end))
        super.unmarkText()
        text = (text as NSString).replacingCharacters(in: range, with: "\u{4F60}\u{597D}")
        selectedRange = NSRange(location: range.location + 2, length: 0)
    }
}

@MainActor
private final class ComposerTextRecorder: NSObject, UITextViewDelegate {
    var text = ""
    func textViewDidChange(_ textView: UITextView) { text = textView.text }
}

@MainActor
private struct ComposerWindowFixture {
    let window: UIWindow
    let host: UIHostingController<AnyView>
    let previousKey: UIWindow?
    func close() {
        host.dismiss(animated: false)
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}

private struct ComposerOfflineImageBytes: YamiboImageDataLoading {
    let bytes: Data
    func data(for source: YamiboImageSource) async throws -> Data { bytes }
    func cachedData(for source: YamiboImageSource) -> Data? { bytes }
}

private actor ComposerPageRepository: ForumPageLoading {
    struct Counts: Sendable { var loads = 0; var submissions = 0; var uploads = 0 }
    let page: ForumPageDocument
    private(set) var counts = Counts()
    init(page: ForumPageDocument) { self.page = page }
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult { counts.loads += 1; return .page(page) }
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        counts.submissions += 1
        XCTFail("Composer fixtures must never submit")
        throw ForumPageError.invalidForm
    }
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        counts.uploads += 1
        XCTFail("Composer fixtures must never upload")
        throw ForumPageError.unsupportedUpload
    }
}

private actor ComposerConfirmedReplyRepository: ForumPageLoading {
    let page: ForumPageDocument
    private(set) var submissionValues: [[String: [String]]] = []

    init(page: ForumPageDocument) { self.page = page }

    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult { .page(page) }

    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        submissionValues.append(values)
        return .page(page)
    }

    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        XCTFail("Reply confirmation must never upload")
        throw ForumPageError.unsupportedUpload
    }
}

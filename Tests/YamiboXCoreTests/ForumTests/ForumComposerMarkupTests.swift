import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumComposerMarkupTests {
    @Test func nestedBBCodeKeepsOriginalDelimitersAndAppliesNativeStyles() {
        let source = "Start [B]bold [i]both[/i][/B]\n[quote][url=https://example.com/?a=1&b=2]link[/url][/quote]"
        let runs = ForumComposerMarkup.parse(source, format: .bbcode)
        #expect(runs.map(\.text).joined() == "Start bold both\nlink")
        #expect(runs.first { $0.text == "both" }?.wrappers.map(\.name) == ["b", "i"])
        #expect(runs.first { $0.text == "both" }?.wrappers.first?.style.isBold == true)
        #expect(runs.last?.wrappers.first?.isQuote == true)
        #expect(runs.last?.wrappers.last?.link?.absoluteString == "https://example.com/?a=1&b=2")
        #expect(ForumComposerMarkup.serialize(runs, format: .bbcode) == source)
    }

    @Test(arguments: ["[hide=10][b]secret[/b][/hide]", "[table][tr][td]cell[/td][/tr][/table]", "[code][b]literal[/b]{:1_910:}[/code]", "[b]", "[b][/b]", "[b][i]crossed[/b][/i]"])
    func unsupportedEmptyOrMalformedMarkupIsNeverDiscarded(_ source: String) {
        let runs = ForumComposerMarkup.parse(source, format: .bbcode)
        #expect(ForumComposerMarkup.serialize(runs, format: .bbcode) == source)
        #expect(!runs.map(\.text).joined().isEmpty)
    }

    @Test func editingTextAcrossStylesPreservesBalancedTagsAndOpaqueContent() {
        let source = "[b]first[/b] middle [i]last[/i][hide=10]unchanged[/hide]"
        var runs = ForumComposerMarkup.parse(source, format: .bbcode)
        runs[0].text = "edited"
        runs[1].text = ""
        runs[2].text = "tail"
        let updated = ForumComposerMarkup.serialize(runs, format: .bbcode)
        #expect(updated == "[b]edited[/b][i]tail[/i][hide=10]unchanged[/hide]")
        #expect(ForumComposerMarkup.parse(updated, format: .bbcode).map(\.text).joined() == "editedtail[hide=10]unchanged[/hide]")
    }

    @Test func emoticonsImagesAndUploadedAttachmentCodesRoundTrip() {
        let source = "A{:1_910:}[img]https://bbs.yamibo.com/example.png[/img][attachimg]42[/attachimg]B"
        let runs = ForumComposerMarkup.parse(source, format: .bbcode)
        #expect(runs.filter(\.isAttachment).count == 3)
        #expect(runs.filter(\.isAttachment).first?.imageURL?.path == "/static/image/smiley/default/89.png")
        #expect(runs.filter(\.isAttachment).last?.imageURL == nil)
        #expect(runs.map(\.text).joined() == "A\u{FFFC}\u{FFFC}\u{FFFC}B")
        #expect(ForumComposerMarkup.serialize(runs, format: .bbcode) == source)
    }

    @Test func htmlUsesExistingAttributeAndEntityParsersWithoutExecutingMarkup() {
        let source = #"<b>A&amp;B</b><br><a href="https://example.com/?a=1&amp;b=2">link</a><img src="https://bbs.yamibo.com/static/image/smiley/default/89.png"><script>alert('never')</script>"#
        let runs = ForumComposerMarkup.parse(source, format: .html)
        #expect(runs.map(\.text).joined() == "A&B\nlink\u{FFFC}<script>alert('never')</script>")
        #expect(runs.first?.wrappers.first?.style.isBold == true)
        #expect(runs.first { $0.text == "link" }?.wrappers.last?.link?.absoluteString == "https://example.com/?a=1&b=2")
        #expect(ForumComposerMarkup.serialize(runs, format: .html) == source)
        var edited = runs
        edited[0].text = "<new>&\n"
        #expect(ForumComposerMarkup.serialize(edited, format: .html).hasPrefix("<b>&lt;new&gt;&amp;<br></b>"))
    }

    @Test func htmlParagraphsRenderAsEditableLineBreaksAndPlainTextIsEscapedOnce() {
        let runs = ForumComposerMarkup.parse("<p>First</p><p><b>Second</b></p>", format: .html)
        #expect(runs.map(\.text).joined() == "First\nSecond\n")
        #expect(ForumComposerMarkup.serialize(runs, format: .html) == "First<br><b>Second</b><br>")
        let plain = ForumComposerMarkup.parse("<draft>&\n", format: .plainText)
        #expect(plain.map(\.text).joined() == "<draft>&\n")
        #expect(ForumComposerMarkup.serialize(plain, format: .html) == "&lt;draft&gt;&amp;<br>")
    }

    @Test(arguments: [
        "<div align=\"center\">Heading</div>",
        "<p dir=\"rtl\">Heading</p>",
        "<p class=\"custom\" id=\"heading\">Heading</p>",
        "<div data-layout=\"custom\">Heading</div>",
        "<p style=\"\">Heading</p>"
    ])
    func attributedParagraphsSurviveUnrelatedEdits(_ paragraph: String) throws {
        let source = paragraph + "Tail"
        var runs = ForumComposerMarkup.parse(source, format: .html)
        #expect(runs.first?.isLiteral == true)
        #expect(ForumComposerMarkup.serialize(runs, format: .html) == source)
        let index = try #require(runs.indices.last)
        runs[index].text += "!"
        #expect(ForumComposerMarkup.serialize(runs, format: .html) == source + "!")
    }

    @Test(arguments: [("strong", "b"), ("em", "i"), ("strike", "s"), ("blockquote", "quote")])
    func equivalentTagsShareFormattingIdentityWithoutRewritingSource(_ names: (String, String)) throws {
        let source = "<\(names.0)>Body</\(names.0)>"
        let runs = ForumComposerMarkup.parse(source, format: .html)
        let wrapper = try #require(runs.first?.wrappers.first)
        #expect(wrapper.name == names.0)
        #expect(wrapper.formattingName == names.1)
        #expect(ForumComposerMarkup.serialize(runs, format: .html) == source)
    }

    @Test func htmlEntityDecodingIsSinglePassAndPreservesUnicodeAndWhitespace() {
        let source = "  &amp;lt; &#x1F642; &#10; &#20013;  "
        let runs = ForumComposerMarkup.parse(source, format: .html)
        #expect(runs.map(\.text).joined() == "  &lt; \u{1F642} \n 中  ")
        #expect(ForumComposerMarkup.serialize(runs, format: .html) == source)
    }

    @Test func authoredColorsUseExistingStylePolicyAndUnsafeImagesNeverLoad() {
        let runs = ForumComposerMarkup.parse("[color=red][size=4]red[/size][/color]", format: .bbcode)
        #expect(runs.first?.wrappers.first?.style.foregroundHex == "#FF0000")
        #expect(runs.first?.wrappers.last?.style.relativeFontSize == 1.125)
        let unsafe = ForumComposerMarkup.parse(#"<img src="javascript:alert(1)"><img src="file:///tmp/private.png">"#, format: .html)
        #expect(unsafe.allSatisfy { $0.imageURL == nil && !$0.isAttachment })
    }

    @Test func deeplyNestedMarkupRemainsBoundedAndLossless() {
        let source = String(repeating: "[b]", count: 100) + "body" + String(repeating: "[/b]", count: 100)
        #expect(ForumComposerMarkup.serialize(ForumComposerMarkup.parse(source, format: .bbcode), format: .bbcode) == source)
    }
}

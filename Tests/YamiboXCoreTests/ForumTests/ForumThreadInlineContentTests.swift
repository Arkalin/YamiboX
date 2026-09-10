import Foundation
import Testing
@testable import YamiboXCore

@Suite("Forum Inline Content")
struct ForumThreadInlineContentTests {
    private let smiley = "<img src='static/image/smiley/default/smile.gif' alt='smile'>"

    @Test func emoticonsStayInTextAndPreserveLineBreaksStylesAndLinks() throws {
        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML:
            "  <i>前😀\(smiley)后</i>\(smiley)<br><a href='thread-1-1-1.html'>链接\(smiley)</a>  "
        )
        #expect(blocks.count == 1)
        guard case let .text(text) = try #require(blocks.first).kind else {
            Issue.record("Expected inline text")
            return
        }
        #expect(text.text == "前😀\u{FFFC}后\u{FFFC}\n链接\u{FFFC}")
        #expect(text.inlineImages.map(\.start) == [2, 4, 8])
        #expect(text.styleRuns == [ForumThreadTextStyleRun(start: 0, length: 4, style: ForumThreadTextStyle(isItalic: true))])
        #expect(text.links.first?.start == 6)
        #expect(text.links.first?.length == 3)
        #expect(text.inlineImages.last?.image.linkURL == text.links.first?.url)
    }

    @Test func standaloneAndNestedEmoticonsRemainInlineButPhotosStayBlocks() throws {
        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML:
            "\(smiley)\(smiley)<img src='data/attachment/photo.jpg'><blockquote>quote\(smiley)</blockquote>"
        )
        #expect(blocks.count == 3)
        guard case let .text(text) = blocks[0].kind,
              case let .image(photo) = blocks[1].kind,
              case let .quote(quote) = blocks[2].kind,
              case let .text(quoteText) = try #require(quote.first).kind else {
            Issue.record("Expected text, photo and quote")
            return
        }
        #expect(text.inlineImages.count == 2)
        #expect(!photo.isEmoticon)
        #expect(quoteText.inlineImages.first?.start == 5)
    }

    @Test func chunkingRebasesEmoticonsWithoutLosingThem() throws {
        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML:
            String(repeating: "字", count: 319) + smiley + smiley + "尾"
        )
        let texts = blocks.compactMap { block -> ForumThreadTextBlock? in
            guard case let .text(text) = block.kind else { return nil }
            return text
        }
        #expect(texts.map { $0.inlineImages.map(\.start) } == [[319], [0]])
        #expect(texts.map(\.text).joined().count == 322)
    }

    @Test(arguments: ["<i>text</i>", "<em>text</em>", "<span style='font-style: italic'>text</span>",
                      "<p style='font-style: OBLIQUE'>text</p>", "<font style='font-style:italic'>text</font>"])
    func italicMarkupIsPreserved(html: String) throws {
        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: html)
        guard case let .text(text) = try #require(blocks.first).kind else {
            Issue.record("Expected text")
            return
        }
        #expect(text.styleRuns.first?.style.isItalic == true)
    }

    @Test func decodingOldCachedTextDefaultsToNoInlineImages() throws {
        let old = Data(#"{"text":"old","alignment":"start","links":[],"styleRuns":[],"rubies":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ForumThreadTextBlock.self, from: old).inlineImages.isEmpty)
        let blocks = try ForumThreadHTMLBlockParser.parseBlocks(fromHTML: smiley)
        #expect(try JSONDecoder().decode([ForumThreadContentBlock].self, from: JSONEncoder().encode(blocks)) == blocks)
    }

    @Test func emoticonOnlyPostIsNotDiscardedAndPlainTextHasNoAttachmentMarkers() throws {
        let page = try ForumThreadPageHTMLParser.parsePage(
            from: "<div id='post_1'><div class='message' id='postmessage_1'>\(smiley)</div></div>",
            thread: ThreadIdentity(tid: "1"), fallbackTitle: nil
        )
        #expect(page.posts.count == 1)
        #expect(page.posts.first?.contentText == "")
    }
}

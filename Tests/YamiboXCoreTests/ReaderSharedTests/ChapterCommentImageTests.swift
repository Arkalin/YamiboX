import Foundation
import Testing
@testable import YamiboXCore

@Suite("Chapter Comment Images")
struct ChapterCommentImageTests {
    private let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100", title: "Chapter")
    private let mixed = "<b>Before</b><img file='data/attachment/one.jpg' src='static/image/common/none.gif' alt='First'><a href='https://example.com'>Between</a><img zoomfile='//bbs.yamibo.com/data/attachment/two.jpg'><em>After</em>"

    @Test(arguments: [true, false])
    func desktopAndMobileSourcesKeepOrderedUnstyledContent(mobile: Bool) throws {
        let comment = mobile
            ? "<div id='commentdetail_1'><div class='mtxt'>\(mixed)</div></div>"
            : "<div class='pstl'><div class='psti'>\(mixed)</div></div>"
        let rating = mobile
            ? "<li class='flex-box'><div><a>Reader</a></div><div>+1</div><div>\(mixed)</div></li>"
            : "<table><tr><td><a>Reader</a></td><td>+1</td><td class='xg1'>\(mixed)</td></tr></table>"
        let html = """
        <div id='post_100'><div id='postmessage_100'>Chapter</div></div>
        <div id='comment_100'>\(comment)</div><div id='ratelog_100'>\(rating)</div>
        <div id='post_101'><div class='message' id='postmessage_101'>\(mixed)</div></div>
        """
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)
        #expect(page.comments.map(\.source) == [.postComment, .ratingReason, .reply])
        for comment in page.comments {
            let blocks = try #require(comment.contentBlocks)
            #expect(blocks.map(describe) == ["Before", "one.jpg", "Between", "two.jpg", "After"])
            #expect(comment.body == "BeforeBetweenAfter")
            #expect(comment.bodyBlocks == nil)
            #expect(blocks.compactMap { if case let .text(text) = $0.kind { text.styleRuns.isEmpty && text.links.isEmpty } else { nil } }.allSatisfy { $0 })
            #expect(images(comment).allSatisfy { $0.url.scheme == "https" && $0.linkURL == nil })
        }
        #expect(try JSONDecoder().decode(ChapterCommentsPage.self, from: JSONEncoder().encode(page)) == page)
    }

    @Test func imageOnlyRatingsAndFullReasonsAreRetained() throws {
        let photo = "<img zsrc='data/attachment/photo.png' src='static/image/common/none.gif'>"
        let initial = "<div id='ratelog_100'><table><tr><td>Reader</td><td class='xg1'>\(photo)</td></tr></table></div>"
        #expect(try ChapterCommentsHTMLParser.parseInitialPage(html: initial, target: target).comments.first?.contentBlocks?.count == 1)
        let full = """
        <ul class='post_box'>
        <li class='flex-box'><span class='z'>积分 +1</span><span class='z'>Reader</span><span class='y'>Time</span></li>
        <li class='flex-box'><span class='z'>\(photo)</span></li>
        </ul>
        """
        let comment = try #require(ChapterCommentsHTMLParser.parseFullRatingReasonsPage(html: full, target: target).first)
        #expect(comment.body.isEmpty)
        #expect(images(comment).map(\.url.lastPathComponent) == ["photo.png"])
    }

    @Test func continuationIncludesAttachmentsOnceAndExcludesUnrelatedImages() throws {
        let html = """
        <div id='post_101'>
        <div class='avatar'><img src='avatar.jpg'></div>
        <div id='postmessage_101'>
        <div class='quote'>Quoted<img src='quote.jpg'></div><blockquote><img src='quote2.jpg'></blockquote>
        <i class='pstatus'>Edited<img src='edit.jpg'></i><div hidden><img src='hidden.jpg'></div>
        <div style='display: none'><img src='hidden2.jpg'></div><img style='visibility: hidden' src='hidden3.jpg'>
        <img src='data:abc'><img src='javascript:alert(1)'><img src='static/image/common/none.gif'><img>
        <img file='data/attachment/one.jpg'><img file='data/attachment/one.jpg'>
        <img src='static/image/smiley/default/smile.gif' alt='smile'>
        </div>
        <ul class='img_one'><li><img src='https://bbs.yamibo.com/data/attachment/one.jpg'></li><li><img zsrc='data/attachment/two.jpg'></li></ul>
        <div class='pattl'><img id='aimg_2' zoomfile='data/attachment/two.jpg'><img id='aimg_3' src='data/attachment/three.jpg'><img src='icon.jpg'></div>
        <div id='comment_101'><ul class='img_one'><li><img src='other-comment.jpg'></li></ul></div>
        <a href='forum.php?mod=attachment&amp;aid=1'>download.zip</a>
        </div>
        """
        let page = try ChapterCommentsHTMLParser.parseContinuationPage(html: html, target: target, view: 2)
        let comment = try #require(page.comments.first)
        #expect(images(comment).map(\.url.lastPathComponent) == ["one.jpg", "one.jpg", "two.jpg", "three.jpg"])
        #expect(comment.body.isEmpty)
        #expect(comment.bodyBlocks?.flatMap(\.inlineImages).count == 1)
        #expect(Set(comment.contentBlocks?.map(\.id) ?? []).count == comment.contentBlocks?.count)
    }

    @Test func attachmentOnlyReplyAndHiddenRows() throws {
        let html = """
        <div id='post_101'><div id='postmessage_101'></div><ul class='img_one'><li><img src='attachment.png'></li></ul></div>
        <div id='post_102' hidden><div id='postmessage_102'><img src='hidden.png'></div></div>
        <div id='post_103'><div id='postmessage_103'><div class='quote'><img src='quote.png'></div></div></div>
        """
        let page = try ChapterCommentsHTMLParser.parseContinuationPage(html: html, target: target, view: 2)
        #expect(page.comments.count == 2)
        #expect(page.comments.last?.quoteBlocks?.count == 1)
        #expect(images(try #require(page.comments.first)).map(\.url.lastPathComponent) == ["attachment.png"])
    }

    @Test func italicContentIsUnstyledRatherThanMistakenForEditMetadata() throws {
        let html = """
        <div id='post_101'><div id='postmessage_101'>
        <i>Text<img src='photo.png'></i><span class='edited'>Edited<img src='edit.png'></span>
        </div></div>
        """
        let comment = try #require(ChapterCommentsHTMLParser.parseContinuationPage(html: html, target: target, view: 2).comments.first)
        #expect(comment.body == "Text")
        #expect(comment.contentBlocks?.map(describe) == ["Text", "photo.png"])
        if case let .text(block) = comment.contentBlocks?.first?.kind {
            #expect(block.styleRuns.isEmpty)
        } else {
            Issue.record("Expected unstyled text before the photo")
        }
    }

    private func images(_ comment: ChapterComment) -> [ForumThreadImageBlock] {
        (comment.contentBlocks ?? []).compactMap { if case let .image(image) = $0.kind { image } else { nil } }
    }

    private func describe(_ block: ForumThreadContentBlock) -> String {
        switch block.kind {
        case let .text(text): text.text
        case let .image(image): image.url.lastPathComponent
        default: "unexpected"
        }
    }
}

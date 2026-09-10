import Foundation
import Testing
@testable import YamiboXCore

@Suite("Chapter Comment Emoticons")
struct ChapterCommentEmoticonTests {
    private let target = ReaderChapterCommentTarget(threadID: "42", view: 1, ownerPostID: "100", title: "Chapter")
    private let smiley = "<img src='static/image/smiley/default/smile.gif' alt='smile'>"

    @Test func emoticonOnlyPostCommentsAreNotTreatedAsEmpty() throws {
        let html = """
        <div id='comment_100'>
        <div class='pstl'><div class='psti'>\(smiley)<span class='xg1'>Time</span></div></div>
        <div id='commentdetail_1'><div class='mtxt'>\(smiley)</div></div>
        </div>
        """
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)
        #expect(page.comments.count == 2)
        #expect(page.comments.allSatisfy { $0.body.isEmpty && $0.bodyBlocks?.first?.inlineImages.count == 1 })
    }

    @Test(arguments: [true, false])
    func desktopAndMobileCommentsRatingsAndRepliesKeepEmoticons(mobile: Bool) throws {
        let content = "前😀\(smiley)\(smiley)后"
        let comments = mobile
            ? "<div id='commentdetail_1'><a>Reader</a><div class='mtxt'>\(content)</div><span class='mtime'>Time</span></div>"
            : "<div class='pstl'><div class='psta'><a>Reader</a></div><div class='psti'>\(content)<span class='xg1'>Time</span></div></div>"
        let ratings = mobile
            ? "<li class='flex-box'><div><a>Reader</a></div><div>+1</div><div>\(smiley)</div></li>"
            : "<table><tr><td><a>Reader</a></td><td>+1</td><td class='xg1'>\(smiley)</td></tr></table>"
        let html = """
        <div id='post_100'><div id='postmessage_100'>Chapter</div></div>
        <div id='comment_100'>\(comments)</div>
        <div id='ratelog_100'>\(ratings)</div>
        <div id='post_101'><div id='postmessage_101'>\(smiley)</div></div>
        """
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)
        #expect(page.comments.map(\.source) == [.postComment, .ratingReason, .reply])
        #expect(page.comments.map(\.body) == ["前😀后", "", ""])
        #expect(page.comments.first?.metadata == "Time")
        let block = try #require(page.comments.first?.bodyBlocks?.first)
        #expect(block.text == "前😀\u{FFFC}\u{FFFC}后")
        #expect(block.inlineImages.map(\.start) == [2, 3])
        #expect(block.inlineImages.allSatisfy { $0.image.isEmoticon && $0.image.altText == "smile" })
        #expect(block.inlineImages.first?.image.url.absoluteString == "https://bbs.yamibo.com/static/image/smiley/default/smile.gif")
        #expect(page.comments.dropFirst().allSatisfy { $0.bodyBlocks?.first?.inlineImages.count == 1 })
        #expect(try JSONDecoder().decode(ChapterCommentsPage.self, from: JSONEncoder().encode(page)) == page)
    }

    @Test func continuationPreservesLazyEmoticonsAndStillExcludesQuotesPhotosAndEditMetadata() throws {
        let html = """
        <div id='post_101'><div id='postmessage_101'>
        <div class='quote'>Quoted \(smiley)</div><blockquote>Also quoted \(smiley)</blockquote>
        <i class='pstatus'>Edited \(smiley)</i>
        <img src='static/image/common/none.gif' file='//bbs.yamibo.com/static/image/smiley/default/89.png' alt='happy'>
        <img src='data/attachment/photo.jpg'>
        </div></div>
        """
        let page = try ChapterCommentsHTMLParser.parseContinuationPage(html: html, target: target, view: 2)
        let comment = try #require(page.comments.first)
        #expect(comment.body.isEmpty)
        #expect(comment.bodyBlocks?.count == 1)
        let block = try #require(comment.bodyBlocks?.first)
        #expect(block.text == "\u{FFFC}")
        #expect(block.inlineImages.count == 1)
        #expect(block.inlineImages.first?.image.url.absoluteString == "https://bbs.yamibo.com/static/image/smiley/default/89.png")
    }

    @Test func fullRatingReasonsKeepEmoticonOnlyAndCustomizedTemplateReasons() throws {
        let html = """
        <ul class='post_box'>
        <li class='flex-box'><span class='z'>积分 +1</span><span class='z'>Reader</span><span class='y'>Time</span></li>
        <li class='flex-box'><span class='z'>\(smiley)</span></li>
        <li class='flex-box'><span class='z'>积分 +1</span><span class='z'>Reader</span><span class='y'>Time</span></li>
        <li class='flex-box'><span class='z'>我很赞同\(smiley)</span></li>
        </ul>
        """
        let comments = try ChapterCommentsHTMLParser.parseFullRatingReasonsPage(html: html, target: target)
        #expect(comments.count == 2)
        #expect(comments.allSatisfy { $0.bodyBlocks?.first?.inlineImages.count == 1 })
    }

    @Test func longMixedContentKeepsAllTextAndRebasesEmoticonsAcrossChunks() throws {
        let prefix = String(repeating: "字", count: 319)
        let html = """
        <div id='comment_100'><div class='pstl'><div class='psti'>
        \(prefix)\(smiley)\(smiley)<br>尾<table><tr><td>一</td><td>二\(smiley)</td></tr></table>
        </div></div></div>
        """
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)
        let blocks = try #require(page.comments.first?.bodyBlocks)
        #expect(blocks.flatMap(\.inlineImages).count == 3)
        #expect(blocks.map(\.text).joined().replacingOccurrences(of: "\u{FFFC}", with: "").contains(prefix + "\n尾"))
        for block in blocks {
            for inline in block.inlineImages {
                #expect(Array(block.text)[inline.start] == "\u{FFFC}")
            }
        }
    }

    @Test func oldSerializedCommentsStillDecodeAsPlainText() throws {
        let data = Data(#"{"id":"1","source":"reply","authorName":"Reader","body":"old"}"#.utf8)
        let comment = try JSONDecoder().decode(ChapterComment.self, from: data)
        #expect(comment.body == "old")
        #expect(comment.bodyBlocks == nil)
    }
}

import Foundation
import Testing
@testable import YamiboXCore

@Suite("Image Reference Extraction Rules")
struct ImageReferenceExtractionTests {
    @Test func mangaPageExtractionPrefersZsrcFiltersSmileyAndNormalizesRelativeURLs() throws {
        let urls = MangaHTMLParser.extractImageURLs(
            from: """
            <html><body>
              <div class="message">
                <img zsrc="data/attachment/forum/page-1.jpg" src="static/image/common/none.gif" />
                <img src="data/attachment/forum/page-2.jpg" />
                <img src="static/image/smiley/default/smile.gif" />
                <img src="data/attachment/forum/page-2.jpg" />
              </div>
            </body></html>
            """
        )

        #expect(urls.map(\.absoluteString) == [
            "https://bbs.yamibo.com/data/attachment/forum/page-1.jpg",
            "https://bbs.yamibo.com/data/attachment/forum/page-2.jpg"
        ])
    }

    @Test func forumContentExtractionPrefersFileAttributeAndMarksEmoticons() throws {
        let page = try ForumThreadPageHTMLParser.parsePage(
            from: """
            <html><body>
              <div id="post_1001">
                <div class="authi">
                  <a class="author" href="home.php?mod=space&uid=42&mobile=2">楼主名</a>
                </div>
                <div class="message" id="postmessage_1001">
                  <img file="data/attachment/forum/full.png" zoomfile="data/attachment/forum/zoom.png" alt="附图">
                  <img src="static/image/smiley/default/titter.gif" alt="表情">
                </div>
              </div>
            </body></html>
            """,
            thread: ThreadIdentity(tid: "700"),
            fallbackTitle: nil
        )

        let imageBlocks = page.posts.flatMap(\.contentBlocks).compactMap { block -> ForumThreadImageBlock? in
            if case let .image(imageBlock) = block.kind {
                return imageBlock
            }
            return nil
        }
        #expect(imageBlocks.count == 2)
        #expect(imageBlocks.first?.url.absoluteString == "https://bbs.yamibo.com/data/attachment/forum/full.png")
        #expect(imageBlocks.first?.isEmoticon == false)
        #expect(imageBlocks.last?.url.absoluteString == "https://bbs.yamibo.com/static/image/smiley/default/titter.gif")
        #expect(imageBlocks.last?.isEmoticon == true)
    }

    @Test func forumPostImagesFilterForumChromeAssets() throws {
        let page = try ForumThreadPageHTMLParser.parsePage(
            from: """
            <html><body>
              <div id="post_1002">
                <div class="authi">
                  <a class="author" href="home.php?mod=space&uid=42&mobile=2">楼主名</a>
                </div>
                <div class="message" id="postmessage_1002">
                  <img zsrc="data/attachment/forum/inline.jpg" src="static/image/common/none.gif">
                  <img src="static/image/filetype/common.gif">
                </div>
              </div>
            </body></html>
            """,
            thread: ThreadIdentity(tid: "701"),
            fallbackTitle: nil
        )

        #expect(page.posts.flatMap(\.images).map(\.url) == ["data/attachment/forum/inline.jpg"])
    }
}

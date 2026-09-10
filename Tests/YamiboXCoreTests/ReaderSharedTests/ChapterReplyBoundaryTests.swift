import Foundation
import Testing
@testable import YamiboXCore

@Suite
struct ChapterReplyBoundaryTests {
    private let target = ReaderChapterCommentTarget(threadID: "123", view: 1, ownerPostID: "456", authorID: "42")
    private let html = """
    <html><body><div id="post_456"><div class="authi"><a href="home.php?mod=space&amp;uid=42">Author</a></div>
    <div id="postmessage_456">Chapter</div></div></body></html>
    """

    @Test func filteredPageCannotProveThreadEnd() throws {
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target)
        #expect(page.nextView == nil)
        #expect(page.isThreadEndConfirmed != true)
        let unfiltered = try ChapterCommentsHTMLParser.parseInitialPage(html: html, target: target, isUnfiltered: true)
        #expect(unfiltered.isThreadEndConfirmed == true)
    }

    @Test func paginationAndMissingTargetCannotProveThreadEnd() throws {
        let paged = html.replacingOccurrences(of: "</body>", with: """
        <div class="pg"><strong>1</strong><a href="forum.php?mod=viewthread&amp;tid=123&amp;page=2">2</a></div></body>
        """)
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: paged, target: target, isUnfiltered: true)
        #expect(page.nextView == 2)
        #expect(page.isThreadEndConfirmed != true)
        let missing = try ChapterCommentsHTMLParser.parseInitialPage(html: html.replacingOccurrences(of: "456", with: "999"), target: target, isUnfiltered: true)
        #expect(missing.isThreadEndConfirmed != true)
    }

    @Test func laterOwnerPostClosesBoundary() throws {
        let later = html.replacingOccurrences(of: "</body>", with: """
        <div id="post_789"><div class="authi"><a href="home.php?mod=space&amp;uid=42">Author</a></div>
        <div id="postmessage_789">Next chapter</div></div></body>
        """)
        let page = try ChapterCommentsHTMLParser.parseInitialPage(html: later, target: target, isUnfiltered: true)
        #expect(page.isBoundaryClosed)
        #expect(page.isThreadEndConfirmed != true)
    }

    @Test func legacyPageDecodingDoesNotInventBoundaryProof() throws {
        let data = Data(#"{"target":{"threadID":"123","view":1,"ownerPostID":"456"},"comments":[],"isBoundaryClosed":false}"#.utf8)
        let page = try JSONDecoder().decode(ChapterCommentsPage.self, from: data)
        #expect(page.isThreadEndConfirmed == nil)
    }
}

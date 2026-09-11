import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumComposerContextTests {
    @Test func capabilitiesAreReadBeforeEditorChromeAndScriptsAreRemoved() throws {
        let html = #"""
        <script>var isfirstpost = 1; var allowbbcode = parseInt('1'); var allowimgcode = parseInt('0'); var allowmediacode = 0;</script>
        <div id="e_menus"><a id="e_cst2_ruby">Ruby</a><a id="e_collapse">Collapse</a></div>
        <form id="postform" action="forum.php?mod=post&amp;action=newthread&amp;fid=5" method="post">
        <input name="formhash" type="hidden" value="token"><input name="subject"><textarea name="message"></textarea><button type="submit">Submit</button>
        <img id="aimg_123" file="data/attachment/a.png" alt="Picture"><input name="attachnew[124][description]" value="">
        </form>
        <script src="data/cache/common_postimg.js?version=1"></script>
        """#
        let page = try ForumFormPageParser.parse(html: html, url: URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=5")!)
        let context = try #require(page.composerContext)
        #expect(context.target.kind == .newThread)
        #expect(context.bbcode == .allowed)
        #expect(context.images == .denied)
        #expect(context.capability(for: .media) == .denied)
        #expect(context.tags[.ruby] == .allowed)
        #expect(context.tags[.collapse] == .allowed)
        #expect(context.attachments.first?.previewURL?.absoluteString == "https://bbs.yamibo.com/data/attachment/a.png")
        #expect(context.attachments.last?.previewURL == nil)
        #expect(context.backgroundCatalogURL?.path == "/data/cache/common_postimg.js")
    }

    @Test func missingButtonsDoNotImplyDenialAndScriptExpressionsAreNotEvaluated() throws {
        let document = try KannaSoup.parseBodyFragment(#"<script>var allowbbcode = evil();</script><form id="postform"></form>"#)
        let context = try #require(ForumComposerContextParser.parse(in: document, pageURL: YamiboDomain.baseURL, isFirstPost: false))
        #expect(context.bbcode == .unknown)
        #expect(context.capability(for: .ruby) == .unknown)
        #expect(context.capability(for: .begin) == .denied)
    }

    @Test func backgroundNamesMustComeFromTheLiteralCatalog() {
        let script = #"var postimg_type = new Array();postimg_type['hrline']=['line.png'];postimg_type['postbg']=['bg.png','../bad.png','bg.png','bad.svg'];evil();"#
        let backgrounds = ForumComposerContextParser.backgrounds(in: script, baseURL: URL(string: "https://bbs.yamibo.com/forum.php?mod=post")!)
        #expect(backgrounds.map(\.name) == ["bg.png"])
        #expect(backgrounds.first?.imageURL.absoluteString == "https://bbs.yamibo.com/static/image/postbg/bg.png")
        #expect(ForumComposerContextParser.backgrounds(in: "postimg_type['postbg'] = fetch('/secret')", baseURL: YamiboDomain.baseURL).isEmpty)
    }

    @Test func draftTargetRoutesDoNotContainTokens() {
        let target = ForumComposerTarget(kind: .reply, forumID: "5", threadID: "123", replyPostID: "456")
        let query = URLComponents(url: target.editorURL!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Set(query.map(\.name)) == ["mod", "action", "fid", "tid", "repquote"])
    }

    @Test func htmlPasteConvertsAnAllowlistWithoutExecutingOrFetchingImages() throws {
        let html = #"<p><strong>bold</strong> <a href="javascript:bad()">safe text</a></p><ul><li>one</li><li>two</li></ul><table><tr><td colspan="2">cell</td></tr></table><script>bad()</script><img src="https://track.example.com/pixel" alt="image">"#
        let source = try ForumComposerClipboard.importHTML(html)
        #expect(source.contains("[b]bold[/b]"))
        #expect(source.contains("[list][*]one"))
        #expect(source.contains("[td=2,1]cell[/td]"))
        #expect(!source.contains("javascript") && !source.contains("bad()") && !source.contains("track.example.com"))
    }

    @Test func sourceHistorySurvivesModeChangesAndRestoresExactDelimiters() throws {
        var document = ForumComposerDocument(source: "[B]a[/B]"), history = ForumComposerHistory()
        let before = ForumComposerSelection(sourceRange: .init(location: 4))
        let first = try history.perform(.replaceVisible(.init(location: 1), "b"), in: &document, selection: before, typing: true)
        _ = try history.perform(.replaceSource(.init(location: 5), "c"), in: &document, selection: first.selection, typing: true)
        #expect(document.source == "[B]abc[/B]")
        #expect(try history.undo(in: &document)?.selection == before)
        #expect(document.source == "[B]a[/B]")
        #expect(!history.canUndo && history.canRedo)
        _ = try history.redo(in: &document)
        #expect(document.source == "[B]abc[/B]")
    }
}

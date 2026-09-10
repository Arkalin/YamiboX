import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumPagePurposeTests {
    @Test(arguments: ["newthread", "reply", "edit"])
    func postActionsHaveAnEditorRoute(action: String) throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=\(action)&tid=123"))
        #expect(ForumPagePurpose(url: url) == .postEditor)
        #expect(ForumRouteResolver.resolve(url: url) == .postEditor(url))
        let expected: ForumPostEditorMode = action == "newthread" ? .newThread : action == "reply" ? .reply : .edit
        #expect(ForumPostEditorMode(url: url) == expected)
    }

    @Test(arguments: ["", "&op=edit&blogid=88"])
    func blogCreationAndEditingHaveAnEditorRoute(suffix: String) throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com/home.php?mod=spacecp&ac=blog" + suffix))
        #expect(ForumPagePurpose(url: url) == .blogEditor)
        #expect(ForumRouteResolver.resolve(url: url) == .blogEditor(url))
    }

    @Test(arguments: [
        "/home.php?mod=spacecp&ac=friend&op=add&uid=42",
        "/home.php?mod=spacecp&ac=profile",
        "/forum.php?mod=misc&action=rate&tid=123",
        "/forum.php?mod=misc&action=report&tid=123",
        "/member.php?mod=register",
        "/search.php?mod=forum"
    ])
    func otherFormsHaveAnActionRoute(path: String) throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com" + path))
        #expect(ForumPagePurpose(url: url) == .actionForm)
        #expect(ForumRouteResolver.resolve(url: url) == .actionForm(url))
    }

    @Test(arguments: [
        "/home.php?mod=spacecp&ac=blog&op=delete&blogid=88",
        "/forum.php?mod=post&action=reply&tid=123&replysubmit=yes",
        "/forum.php?mod=post&action=reply&action=delete&tid=123"
    ])
    func mutationURLsRemainConfirmationGatedActions(path: String) throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com" + path))
        #expect(ForumWebPagePolicy.requiresConfirmationToLoad(url))
        #expect(ForumRouteResolver.resolve(url: url) == .actionForm(url))
    }

    @Test(arguments: ["/forum.php?mod=announcement&id=17", "/plugin.php?id=example", "/guide.html"])
    func contentWithoutASpecializedRouteIsADocument(path: String) throws {
        let url = try #require(URL(string: "https://bbs.yamibo.com" + path))
        #expect(ForumRouteResolver.resolve(url: url) == .document(url))
    }

    @Test(arguments: [
        "https://example.com/forum.php?mod=post&action=reply&tid=123",
        "https://bbs.yamibo.com/member.php?mod=logging&action=login"
    ])
    func browserBoundaryPrecedesPagePurpose(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(ForumRouteResolver.resolve(url: url) == .web(url))
    }

    @Test func loadedResponseDeterminesTheScreenInsteadOfTheRequestedURL() {
        let url = YamiboRoute.threadReply(tid: "123", page: 1).url
        #expect(ForumPagePurpose(url: url) == .postEditor)
        #expect(ForumPageDocument(url: url, title: "Permission response", message: "No permission").purpose == .document)
        for (kind, purpose) in [(ForumForm.Kind.thread, ForumPagePurpose.postEditor), (.blog, .blogEditor), (.standard, .actionForm)] {
            let form = ForumForm(id: "form", title: "Form", actionURL: url, kind: kind)
            let document = ForumPageDocument(url: YamiboDomain.baseURL, title: "Response", forms: [form])
            #expect(document.purpose == purpose)
        }
        #expect(ForumPostEditorMode(url: YamiboDomain.baseURL) == nil)
    }

    @Test func mixedDocumentsPreserveTheFirstComposerAsThePrimaryForm() {
        let url = YamiboDomain.baseURL
        let standard = ForumForm(id: "standard", title: "Other form", actionURL: url)
        let blog = ForumForm(id: "blog", title: "Blog", actionURL: url, kind: .blog)
        let post = ForumForm(id: "post", title: "Post", actionURL: url, kind: .thread)
        #expect(ForumPageDocument(url: url, title: "Mixed", forms: [standard, blog, post]).purpose == .blogEditor)
        #expect(ForumPageDocument(url: url, title: "Mixed", forms: [standard, post, blog]).purpose == .postEditor)
    }
}

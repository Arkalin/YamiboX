import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumWebPagePolicyTests {
    @Test(arguments: [
        "https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=16",
        "https://bbs.yamibo.com/home.php?mod=spacecp&ac=profile",
        "https://bbs.yamibo.com/member.php?mod=register",
        "https://bbs.yamibo.com/member.php?mod=logging&action=logout&formhash=fixture"
    ]) func supportedNativePagesDoNotResolveToWeb(raw: String) {
        let url = URL(string: raw)!
        #expect(ForumWebPagePolicy.requiresForumHandling(url))
        if case .web = ForumRouteResolver.resolve(url: url) { Issue.record("Internal page was routed to WebKit") }
    }

    @Test(arguments: [
        "https://bbs.yamibo.com/home.php?mod=space&uid=42&do=friend",
        "https://bbs.yamibo.com/forum.php?mod=announcement&id=1",
        "https://bbs.yamibo.com/plugin.php?id=example"
    ]) func trustedPagesWithoutNativeSupportRemainWeb(raw: String) {
        let url = URL(string: raw)!
        #expect(ForumWebPagePolicy.requiresForumHandling(url))
        #expect(!ForumRouteResolver.supportsNativePage(url))
        #expect(ForumRouteResolver.resolve(url: url) == .web(url))
    }

    @Test(arguments: ["https://example.com/thread-42-1-1.html", "https://bbs.yamibo.com.evil.example/forum.php?mod=forumdisplay&fid=5", "https://bbs.yamibo.com/member.php?mod=logging&action=login"])
    func loginAndExternalPagesRemainWeb(raw: String) {
        let url = URL(string: raw)!
        #expect(!ForumWebPagePolicy.requiresForumHandling(url))
        #expect(ForumRouteResolver.resolve(url: url) == .web(url))
    }

    @Test(arguments: ["formhash=fixture", "action=logout", "op=delete", "profilesubmit=true", "op=buy"])
    func mutationLinksRequireConfirmation(query: String) {
        #expect(ForumWebPagePolicy.requiresConfirmationToLoad(URL(string: "https://bbs.yamibo.com/home.php?" + query)!))
    }

    @Test func submissionSuccessRequiresPositiveEvidenceAndFailureWins() {
        let url = YamiboDomain.baseURL
        #expect(ForumPageDocument(url: url, title: "", message: "发表成功").submissionAccepted)
        #expect(!ForumPageDocument(url: url, title: "", message: "上次发表成功，本次操作失败").submissionAccepted)
        #expect(!ForumPageDocument(url: url, title: "", message: "请稍候").submissionAccepted)
        #expect(ForumWebPagePolicy.secureURL(URL(string: "http://bbs.yamibo.com:80/forum.php")!).scheme == "https")
    }
}

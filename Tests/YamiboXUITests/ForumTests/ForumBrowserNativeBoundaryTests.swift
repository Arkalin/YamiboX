import Foundation
import Testing
@testable import YamiboXUI

@MainActor @Suite struct ForumBrowserNativeBoundaryTests {
    @Test func unknownForumPagesRetainBrowserLocation() {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=announcement&id=17")!
        var forwarded: [URL] = []
        let model = ForumBrowserModel(initialURL: url, onNativeNavigation: { forwarded.append($0) })
        model.load(url)
        #expect(model.currentURL == url)
        #expect(forwarded.isEmpty)
    }

    @Test func fallbackRedirectsAndReloadsStayWebUntilNewUserLink() {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=redirect&goto=findpost&pid=456")!
        let thread = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
        let model = ForumBrowserModel(initialURL: url, nativeFallback: true)
        #expect(!model.shouldRouteNatively(url, method: "GET", isMainFrame: true))
        #expect(!model.shouldRouteNatively(thread, method: "GET", isMainFrame: true))
        model.load(url)
        #expect(!model.shouldRouteNatively(url, method: "GET", isMainFrame: true))
        #expect(model.shouldRouteNatively(thread, method: "GET", isMainFrame: true, isUserLink: true))
    }

    @Test func postAndChildFrameRequestsNeverBecomeNativeGETs() {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
        let model = ForumBrowserModel(initialURL: url)
        #expect(!model.shouldRouteNatively(url, method: "POST", isMainFrame: true, isUserLink: true))
        #expect(!model.shouldRouteNatively(url, method: "GET", isMainFrame: false, isUserLink: true))
        #expect(model.shouldRouteNatively(url, method: "GET", isMainFrame: true))
    }

    @Test func authenticationChangeRearmsFallbackRouting() {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123")!
        let model = ForumBrowserModel(initialURL: url, nativeFallback: true)
        model.rearmNativeRouting()
        #expect(model.shouldRouteNatively(url, method: "GET", isMainFrame: true))
    }

    @Test func directInternalLoadIsForwardedWithoutChangingBrowserLocation() {
        let initialURL = URL(string: "https://example.com")!
        var forwarded: [URL] = []
        let model = ForumBrowserModel(initialURL: initialURL, onNativeNavigation: { forwarded.append($0) })
        let nativeURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=16")!
        model.load(nativeURL)
        #expect(forwarded == [nativeURL])
        #expect(model.currentURL == initialURL)
        #expect(!model.isLoading)
    }

    @Test func loginAndExternalLoadsRemainBrowserLocations() {
        let loginURL = URL(string: "https://bbs.yamibo.com/member.php?mod=logging&action=login")!
        var forwarded: [URL] = []
        let model = ForumBrowserModel(initialURL: loginURL, onNativeNavigation: { forwarded.append($0) })
        model.load(loginURL)
        #expect(model.currentURL == loginURL)
        let external = URL(string: "https://example.com/thread-123-1-1.html")!
        model.load(external)
        #expect(model.currentURL == external)
        #expect(forwarded.isEmpty)
    }
}

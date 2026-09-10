import Foundation
import Testing
@testable import YamiboXUI

@MainActor @Suite struct ForumBrowserNativeBoundaryTests {
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

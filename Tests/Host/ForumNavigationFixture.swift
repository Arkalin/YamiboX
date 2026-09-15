import SwiftUI
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

struct ForumNavigationFixture: View {
    @State private var compact = ProcessInfo.processInfo.environment["FORUM_NAVIGATION_REGULAR"] != "1"
    private let usesNativeWindow = ProcessInfo.processInfo.environment["FORUM_NAVIGATION_NATIVE_WINDOW"] == "1"

    var body: some View {
        VStack(spacing: 0) {
            if !usesNativeWindow {
                HStack {
                    Button("Compact") { compact = true }
                    Button("Regular") { compact = false }
                }
            }
            ForumNavigationFixtureHost(compact: compact, usesNativeWindow: usesNativeWindow)
                .frame(maxWidth: compact && !usesNativeWindow ? 460 : .infinity)
        }
    }
}

private struct ForumNavigationFixtureHost: UIViewControllerRepresentable {
    let compact: Bool
    let usesNativeWindow: Bool

    func makeUIViewController(context: Context) -> UIHostingController<ForumNavigationHostView> {
        let suite = "forum-navigation-fixture-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForumNavigationFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let appContext = YamiboAppContext(
            sessionStore: SessionStore(defaults: UserDefaults(suiteName: suite)!),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suite)!),
            webDAVSyncSettingsStore: WebDAVSyncSettingsStore(defaults: UserDefaults(suiteName: suite)!),
            readerResumeRouteStore: ReaderResumeRouteStore(defaults: UserDefaults(suiteName: suite)!),
            grdbRootDirectory: root, cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: UserDefaults(suiteName: suite)!, clearsWebDataOnReset: false, session: session, imageSession: session
        )
        let controller = UIHostingController(rootView: ForumNavigationHostView(
            dependencies: appContext.forumDependencies, appModel: YamiboAppModel(appContext: appContext)
        ))
        if !usesNativeWindow {
            controller.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
        }
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<ForumNavigationHostView>, context: Context) {
        // Keep the same host and navigator while changing both UIKit and SwiftUI traits.
        if !usesNativeWindow {
            controller.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
        }
    }
}

private final class ForumNavigationFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let tid = items.first { $0.name == "tid" }?.value
        let mode = items.first { $0.name == "mod" }?.value
        let body: String
        if let tid {
            let title = tid == "701" ? "Thread A" : "Thread B"
            body = """
            <html><head><title>\(title) - 百合会</title></head><body>
            <div class="header cl"><h2><a href="forum.php?mod=forumdisplay&amp;fid=5">Test Board</a></h2></div>
            <div class="viewthread"><div class="plc cl" id="pid\(tid)1">
            <div class="display pi pione"><ul class="authi"><li class="mtit"><span class="z">Fixture Author</span></li></ul>
            <div class="message">Body \(title)<br><a href="forum.php?mod=viewthread&amp;tid=702">Open nested B</a></div>
            </div></div></div></body></html>
            """
        } else if mode == "forumdisplay" {
            let rows = [("701", "Thread A"), ("702", "Thread B")].map { tid, title in
                """
                <li class="list"><a href="forum.php?mod=viewthread&amp;tid=\(tid)&amp;mobile=2">
                <div class="threadlist_tit cl"><em>\(title)</em></div></a></li>
                """
            }.joined()
            body = """
            <html><head><title>Test Board - 百合会</title></head><body>
            <div class="header cl"><h2>Test Board</h2></div>
            <div class="threadlist cl"><ul>\(rows)</ul></div></body></html>
            """
        } else {
            body = """
            <html><body><input name="formhash" value="fixture">
            <div class="forumlist cl"><div class="subforumshow cl" href="#sub-forum_2"><h2>Fixture</h2></div>
            <div id="sub-forum_2" class="sub-forum mlist1 cl"><ul><li>
            <a href="forum.php?mod=forumdisplay&amp;fid=5&amp;mobile=2" class="murl"><p class="mtit">Test Board</p></a>
            </li></ul></div></div></body></html>
            """
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

import Observation
import SwiftUI
@testable import YamiboXCore
@testable import YamiboXUI

struct NovelReaderChromeFixture: View {
    @State private var model = NovelReaderChromeFixtureModel()

    var body: some View {
        Text(model.error ?? "Preparing reader")
            .fullScreenCover(item: Binding(
                get: { model.appModel.presentedReaderSession },
                set: { if $0 == nil { model.appModel.dismissPresentedReaderSession() } }
            ), onDismiss: model.appModel.readerCoverDidDismiss) { session in
                ReaderSessionScreen(session: session, appModel: model.appModel)
            }
            .task { await model.prepare() }
    }
}

@MainActor @Observable
private final class NovelReaderChromeFixtureModel {
    let context: YamiboAppContext
    let appModel: YamiboAppModel
    var error: String?
    private var prepared = false

    init() {
        let name = "novel-reader-chrome-fixture"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: UserDefaults(suiteName: name)!),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: name)!),
            grdbRootDirectory: root, cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: UserDefaults(suiteName: name)!, clearsWebDataOnReset: false
        )
        appModel = YamiboAppModel(appContext: context)
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        let environment = ProcessInfo.processInfo.environment
        let title = environment["NOVEL_READER_WORK_TITLE"] ?? "The Reader Fixture"
        let chapterTitle = environment["NOVEL_READER_CHAPTER_TITLE"] ?? "第一章 清晨"
        let thread = ThreadIdentity(tid: "730002")
        let page = ForumThreadPage(thread: thread, title: title, posts: (0..<3).map { index in
            let heading = index == 0 ? chapterTitle : "第\(index + 1)章 新的一天"
            let text = (0..<80).map { "<p>\($0 + 1). 她走到窗边，看见远处的山和街道。阳光照在桌上的书页上，今天的故事才刚刚开始。</p>" }.joined()
            return ForumThreadPost(postID: "730002-\(index)", author: BlogReaderUser(uid: "42", name: "Author"),
                contentHTML: "<strong>\(heading)</strong><br>\(text)", contentText: "")
        }, pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1))
        do {
            try await context.settingsStore.update {
                $0.novelReader = NovelReaderAppearanceSettings(
                    isImmersiveModeEnabled: environment["READER_IMMERSIVE"] == "1", readingMode: .paged,
                    pagedTurnStyle: ReaderPagedTurnStyle(rawValue: environment["READER_STYLE"] ?? "none") ?? .none,
                    pageTurnDirection: environment["READER_RTL"] == "1" ? .rightToLeft : .leftToRight
                )
            }
            try await context.forumCacheStore.saveThreadPage(page, thread: thread, pageNumber: 1, authorID: "42")
            try await context.forumCacheStore.saveThreadPage(page, thread: thread, pageNumber: 1, authorID: nil)
            appModel.presentNovelReader(NovelLaunchContext(threadID: thread.tid, threadTitle: title, source: .forum, authorID: "42"))
        } catch {
            self.error = String(describing: error)
        }
    }
}

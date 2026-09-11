import Observation
import SwiftUI
@testable import YamiboXCore
@testable import YamiboXUI

struct ChapterCommentFilterFixture: View {
    @State private var model = ChapterCommentFilterFixtureModel()
    @State private var showsComments = false

    var body: some View {
        NavigationStack {
            SettingsReadingView(viewModel: model.settings)
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Button("章节评论", systemImage: "text.bubble") { showsComments = true }
                            .accessibilityIdentifier("filter-fixture-open-comments")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button(model.isLoggedIn ? "退出账号" : "登录账号", systemImage: "person.crop.circle") {
                            Task { await model.toggleAccount() }
                        }
                        .accessibilityIdentifier("filter-fixture-account")
                    }
                }
        }
        .sheet(isPresented: $showsComments) {
            ReaderChapterCommentsSheet(
                target: model.chapter, state: .loaded(model.chapter, model.page),
                isLoadingMore: false, loadMoreError: nil, refreshError: nil,
                loadInitial: { _ in }, refresh: { _ in }, loadNext: { model.loadNext() },
                forumDependencies: model.context.forumDependencies, appModel: model.appModel,
                discussionWorkTIDs: [], isNovel: true
            )
        }
        .appTheme(.theme(for: .standard))
        .preferredColorScheme(ProcessInfo.processInfo.environment["CHAPTER_COMMENT_DARK"] == "1" ? .dark : .light)
        .dynamicTypeSize(ProcessInfo.processInfo.environment["CHAPTER_COMMENT_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
        .task { await model.load() }
    }
}

@MainActor
@Observable
private final class ChapterCommentFilterFixtureModel {
    let context: YamiboAppContext
    let appModel: YamiboAppModel
    let settings: SettingsReadingViewModel
    let chapter = ReaderChapterCommentTarget(threadID: "123", view: 1, ownerPostID: "456", title: "第十二章", authorID: "42")
    var page: ChapterCommentsPage
    var isLoggedIn = true

    init() {
        let suite = "chapter-comment-filter-fixture"
        let sessionStore = SessionStore(defaults: UserDefaults(suiteName: suite)!)
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chapter-comment-filter-fixture")
        let context = YamiboAppContext(sessionStore: sessionStore, settingsStore: store,
                                      grdbRootDirectory: root, cachesRootDirectory: root.appendingPathComponent("caches"),
                                      uiDefaults: UserDefaults(suiteName: suite)!, clearsWebDataOnReset: false)
        self.context = context
        appModel = YamiboAppModel(appContext: context)
        let fails = ProcessInfo.processInfo.environment["CHAPTER_COMMENT_FILTER_FAIL_SAVE"] == "1"
        settings = SettingsReadingViewModel(dependencies: context.settingsDependencies, activity: .init(),
                                            updateSettings: { mutate in
            if fails { throw YamiboError.underlying("测试存储不可用") }
            return try await store.update(mutate)
        })
        let allHidden = ProcessInfo.processInfo.environment["CHAPTER_COMMENT_FILTER_ALL_HIDDEN"] == "1"
        let comments: [ChapterComment] = allHidden ? [
            .init(id: "hidden", source: .ratingReason, authorName: "默认评分", body: "我很赞同", authorUID: "2")
        ] : [
            .init(id: "own", source: .ratingReason, authorName: "我的评分", body: "我很赞同", authorUID: "1"),
            .init(id: "hidden", source: .ratingReason, authorName: "默认评分", body: "我很赞同", authorUID: "2"),
            .init(id: "custom", source: .ratingReason, authorName: "认真读者", body: "这一章的对话写得真好。", authorUID: "3"),
            .init(id: "discussion", source: .postComment, authorName: "点评读者", body: "我很赞同", authorUID: "4"),
            .init(id: "reply", source: .reply, authorName: "回复读者", body: "期待下一章。", postID: "789", authorUID: "5")
        ]
        page = .init(target: chapter, comments: comments, isBoundaryClosed: false, nextView: 2)
    }

    func load() async {
        if ProcessInfo.processInfo.environment["CHAPTER_COMMENT_FILTER_KEEP_SETTINGS"] != "1" {
            try? await context.settingsStore.save(.init())
        }
        settings.applyLoadedSettings(await context.settingsStore.load())
        await signIn()
    }

    func toggleAccount() async {
        if isLoggedIn { try? await context.sessionStore.reset(); isLoggedIn = false }
        else { await signIn() }
    }

    private func signIn() async {
        var session = SessionState(cookie: "\(SessionState.authenticationCookieName)=fixture", isLoggedIn: true)
        session.accountUID = "1"
        try? await context.sessionStore.save(session)
        try? await context.profileStore.save(.init(uid: "1", username: "我的评分", userGroup: "", points: 0, partner: 0, totalPoints: 0))
        isLoggedIn = true
    }

    func loadNext() {
        page.comments.append(.init(id: "next", source: .reply, authorName: "下一页读者", body: "加载了下一页评论。", postID: "790", authorUID: "6"))
        page.nextView = nil
        page.isBoundaryClosed = true
    }
}

import Observation
import SwiftUI
@testable import YamiboXCore
@testable import YamiboXUI

struct ChapterCommentFilterFixture: View {
    @State private var model = ChapterCommentFilterFixtureModel()
    @State private var showsComments = false

    var body: some View {
        NavigationStack {
            SettingsReadingView(viewModel: model.settings, peripheralsViewModel: model.peripherals)
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
                isLoadingMore: model.isLoadingMore, loadMoreError: nil, refreshError: nil,
                loadInitial: { _ in await model.loadRemaining() }, refresh: { _ in }, loadNext: { model.loadNext() },
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
    let peripherals: SettingsPeripheralsViewModel
    let chapter = ReaderChapterCommentTarget(threadID: "123", view: 1, ownerPostID: "456", title: "第十二章", authorID: "42")
    var page: ChapterCommentsPage
    var isLoggedIn = true
    var isLoadingMore = false

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
        let activity = SystemSettingsActivity()
        peripherals = SettingsPeripheralsViewModel(dependencies: context.settingsDependencies, activity: activity)
        let fails = ProcessInfo.processInfo.environment["CHAPTER_COMMENT_FILTER_FAIL_SAVE"] == "1"
        settings = SettingsReadingViewModel(dependencies: context.settingsDependencies, activity: activity,
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
        peripherals.applyLoadedSettings(await context.settingsStore.load())
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
        guard page.nextView != nil else { return }
        page.comments.append(.init(id: "next", source: .reply, authorName: "下一页读者", body: "加载了下一页评论。", postID: "790", authorUID: "6"))
        page.nextView = nil
        page.isBoundaryClosed = true
    }

    func loadRemaining() async {
        guard page.nextView != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        loadNext()
    }
}

struct ChapterCommentDiscussionFixture: View {
    @State private var model = ChapterCommentDiscussionFixtureModel()
    @State private var showsComments = true

    var body: some View {
        Button("章节评论") { showsComments = true }
            .sheet(isPresented: $showsComments) {
                ReaderChapterCommentsSheet(
                    target: model.target, state: model.snapshot.state,
                    isLoadingMore: model.snapshot.isLoadingMore,
                    loadMoreError: model.snapshot.loadMoreError, refreshError: model.snapshot.refreshError,
                    loadInitial: { target in await model.prepare(); await model.module.loadAndContinue(target) },
                    refresh: { await model.module.refreshAndContinue($0) },
                    loadNext: { await model.module.continueLoading() },
                    forumDependencies: model.context.forumDependencies, appModel: model.appModel,
                    discussionWorkTIDs: [], isNovel: true,
                    cancelLoading: { model.module.cancelLoading() }, composerActions: model.actions
                )
                .environment(\.dynamicTypeSize, ProcessInfo.processInfo.environment["CHAPTER_COMMENT_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
            }
            .appTheme(.theme(for: .standard))
            .preferredColorScheme(ProcessInfo.processInfo.environment["CHAPTER_COMMENT_DARK"] == "1" ? .dark : .light)
            .dynamicTypeSize(ProcessInfo.processInfo.environment["CHAPTER_COMMENT_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
    }
}

@MainActor @Observable private final class ChapterCommentDiscussionFixtureModel {
    let target = ReaderChapterCommentTarget(threadID: "123", view: 1, ownerPostID: "456", title: "第十二章", authorID: "42")
    let context: YamiboAppContext
    let appModel: YamiboAppModel
    let server = ChapterCommentDiscussionFixtureServer()
    var snapshot = ReaderChapterCommentsSnapshot()
    @ObservationIgnored lazy var module = ReaderChapterCommentsModule(adapter: .init(
        loadInitial: { [server] in await server.initial($0) },
        loadMore: { [server] target, _ in try await server.more(target) }
    ), onChange: { [weak self] snapshot in
        MainActor.assumeIsolated { self?.snapshot = snapshot }
    })

    init() {
        let suite = "chapter-comment-discussion-fixture"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chapter-comment-discussion-fixture")
        context = YamiboAppContext(sessionStore: SessionStore(defaults: UserDefaults(suiteName: suite)!), settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suite)!),
                                  grdbRootDirectory: root, cachesRootDirectory: root.appendingPathComponent("caches"),
                                  uiDefaults: UserDefaults(suiteName: suite)!, clearsWebDataOnReset: false)
        appModel = YamiboAppModel(appContext: context)
    }

    func prepare() async {
        var settings = AppSettings()
        if ProcessInfo.processInfo.environment["CHAPTER_COMMENT_HIDE_ROOT"] == "1" {
            settings.chapterComments.discussions = .init(isEnabled: true, rules: [.init(pattern: "^这段对话让我想起第一章。$")])
        }
        if ProcessInfo.processInfo.environment["CHAPTER_COMMENT_HIDE_BRANCH"] == "1" {
            settings.chapterComments.discussions = .init(isEnabled: true, rules: [.init(pattern: "^是的，这里呼应了她们第一次见面。$")])
        }
        try? await context.settingsStore.save(settings)
    }

    var actions: ReaderChapterCommentComposeActions {
        ReaderChapterCommentComposeActions(loadContext: { tid, pid in
            let authors: [String: BlogReaderUser] = [
                "789": .init(uid: "7", name: "见微"), "790": .init(uid: "42", name: "南枝"),
                "791": .init(name: "远山"), "792": .init(name: "清溪"), "793": .init(name: "小夏"),
                "794": .init(name: "白露"), "795": .init(name: "秋池"), "800": .init(name: "书页")
            ]
            return ForumPostActionContext(threadID: tid, post: .init(postID: pid, author: authors[pid] ?? .init(name: "我"), contentHTML: "", contentText: "正文"), page: 2, formHash: "fixture")
        }, loadRateOptions: { _, _ in .init(availableScores: [1, 2, 5], defaultReasons: []) }, rate: { [server] context, _, reason, _ in
            await server.add(postID: context.post.postID, text: reason, source: .ratingReason)
            return "评分成功"
        }, comment: { [server] context, text in
            await server.add(postID: context.post.postID, text: text, source: .postComment)
            return "点评成功"
        }, makeReplySession: { [server] url in
            ForumPageSession(url: url, repository: ChapterCommentDiscussionComposerRepository(server: server))
        })
    }
}

private actor ChapterCommentDiscussionFixtureServer {
    private var didFail = false
    private var additions: [ChapterComment] = []
    private var initialCount = 0
    private var includesConversation: Bool { ProcessInfo.processInfo.environment["CHAPTER_COMMENT_CONVERSATION_FIXTURE"] == "1" }
    private var removesConversation: Bool {
        initialCount > 1 && ProcessInfo.processInfo.environment["CHAPTER_COMMENT_REMOVE_CONVERSATION_ON_REFRESH"] == "1"
    }

    func initial(_ target: ReaderChapterCommentTarget) -> ChapterCommentsPage {
        initialCount += 1
        return .init(target: target, comments: [
            .init(id: "root", source: .reply, authorName: "见微", metadata: "28楼 · 2026-09-12 12:30", body: "这段对话让我想起第一章。", postID: "789", authorUID: "7"),
            .init(id: "rating", source: .ratingReason, authorName: "远山", metadata: "积分 +2", body: "两个人的心情写得真好。", postID: "789")
        ] + (includesConversation && !removesConversation ? Array(discussionComments.prefix(3)) : []), isBoundaryClosed: false, nextView: 2)
    }

    func more(_ target: ReaderChapterCommentTarget) async throws -> ChapterCommentsPage {
        let delay = Double(ProcessInfo.processInfo.environment["CHAPTER_COMMENT_CONVERSATION_DELAY"] ?? "2") ?? 2
        try await Task.sleep(for: .seconds(delay))
        if ProcessInfo.processInfo.environment["CHAPTER_COMMENT_PAGE_FAIL"] == "1", !didFail {
            didFail = true
            throw URLError(.timedOut)
        }
        let branchComments: [ChapterComment] = removesConversation ? [] : discussionComments + additions
        let extra: [ChapterComment] = includesConversation ? [
            .init(id: "deep", source: .reply, authorName: "清溪", metadata: "31楼 · 2026-09-12 12:43", body: "顺着这条对话继续读。", postID: "792", replyReference: .init(postID: "791")),
            .init(id: "sibling", source: .reply, authorName: "小夏", body: "我想聊另一段情节。", postID: "793", replyReference: .init(postID: "789")),
            .init(id: "sibling-child", source: .reply, authorName: "白露", body: "这是另一条独立对话。", postID: "794", replyReference: .init(postID: "793")),
            .init(id: "branch-side", source: .reply, authorName: "秋池", body: "我也赞同这条解读。", postID: "795", replyReference: .init(postID: "790")),
            .init(id: "branch-rating", source: .ratingReason, authorName: "晚晴", metadata: "积分 +5", body: "这段解答很精彩。", postID: "790")
        ].filter { !removesConversation || $0.id == "sibling" || $0.id == "sibling-child" } : []
        return .init(target: target, comments: branchComments + extra, isBoundaryClosed: true)
    }

    private var discussionComments: [ChapterComment] {
        [
            .init(id: "child", source: .reply, authorName: "南枝", metadata: "29楼 · 2026-09-12 12:40", body: "是的，这里呼应了她们第一次见面。", postID: "790", authorUID: "42", replyReference: .init(postID: "789"), isThreadAuthor: true),
            .init(id: "remark", source: .postComment, authorName: "小满", metadata: "2026-09-12 12:41", body: "谢谢解答！", postID: "790"),
            .init(id: "nested", source: .reply, authorName: "远山", metadata: "30楼 · 2026-09-12 12:42", body: "再读一遍果然发现了。", postID: "791", replyReference: .init(postID: "790")),
            .init(id: "cross", source: .reply, authorName: "书页", body: "回头看第一章，确实是这样。", postID: "800", replyReference: .init(postID: "111"), quoteBlocks: [.init(id: "old-quote", kind: .quote([.init(id: "old-text", kind: .text(.init(text: "第一章：她还记得那天的约定。")))]))])
        ]
    }

    func add(postID: String, text: String, source: ChapterCommentSource) {
        additions.append(.init(id: "submitted-\(additions.count)", source: source, authorName: "我", body: text,
                               postID: source == .reply ? "9\(additions.count)" : postID,
                               replyReference: source == .reply ? .init(postID: postID) : nil))
    }
}

private actor ChapterCommentDiscussionComposerRepository: ForumPageLoading {
    let server: ChapterCommentDiscussionFixtureServer
    init(server: ChapterCommentDiscussionFixtureServer) { self.server = server }

    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult {
        let form = ForumForm(id: "postform", title: "回复", actionURL: url, kind: .thread,
                             fields: [.init(id: "message", name: "message", label: "回复内容", kind: .multiline, initialValues: ["[quote]原帖[/quote]"], isRequired: true)],
                             hiddenValues: [.init(name: "formhash", value: "fixture")], buttons: [.init(id: "send", title: "发表回复")])
        return .page(.init(url: url, title: "回复", forms: [form]))
    }

    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        await server.add(postID: referer.queryItemValue("repquote") ?? "", text: values["message"]?.first ?? "", source: .reply)
        return .page(.init(url: referer, title: "结果", message: "回复发表成功"))
    }

    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        throw URLError(.unsupportedURL)
    }
}

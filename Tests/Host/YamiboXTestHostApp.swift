import SwiftUI
import UIKit
import Network
@testable import YamiboXCore
@testable import YamiboXUI

// A scene-backed host without application services, networking, or persisted user state.
@main
struct YamiboXTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["LIKES_FIXTURE"] == "1" {
                LikeListFixture()
            } else if ProcessInfo.processInfo.environment["IMAGE_BROWSER_FIXTURE"] == "1" {
                ImageBrowserFixture()
            } else if ProcessInfo.processInfo.environment["CREDIT_LOG_FIXTURE"] == "1" {
                CreditLogFixture()
            } else if ProcessInfo.processInfo.environment["FORUM_WEB_FIXTURE"] == "1" {
                ForumWebLayoutFixture()
            } else if ProcessInfo.processInfo.environment["CHAPTER_COMMENT_FILTER_FIXTURE"] == "1" {
                ChapterCommentFilterFixture()
            } else if ProcessInfo.processInfo.environment["CHAPTER_COMMENT_FIXTURE"] == "1" {
                ChapterCommentComposerFixture()
            } else if ProcessInfo.processInfo.environment["FORUM_ATTACHMENT_UPLOAD_FIXTURE"] == "1" {
                ForumPhotoUploadFixture(attachmentFixture: true)
            } else if ProcessInfo.processInfo.environment["FORUM_PHOTO_UPLOAD_FIXTURE"] == "1" {
                ForumPhotoUploadFixture()
            } else if ProcessInfo.processInfo.environment["FORUM_SEND_CRASH_FIXTURE"] == "1" {
                ForumSendCrashFixture()
            } else {
                MangaLongPressFixture()
            }
        }
    }
}

private struct ForumWebLayoutFixture: View {
    @State private var model: ForumBrowserModel?
    @State private var server: ForumWebFixtureServer?
    @State private var handoffs: [URL] = []
    @State private var failure: String?
    private let sessionStore = SessionStore(defaults: UserDefaults(suiteName: "forum-web-fixture")!, key: "session")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let model {
                    IOSForumWebView(model: model, sessionStore: sessionStore)
                } else if let failure {
                    Text(failure)
                } else {
                    ProgressView()
                }
                Text("Native handoffs: \(handoffs.count)")
                    .accessibilityIdentifier("web-fixture-handoffs")
            }
            .navigationTitle("网页布局测试")
            .toolbar {
                Button("刷新") { model?.reload() }
            }
        }
        .task {
            guard server == nil else { return }
            do {
                let server = try ForumWebFixtureServer()
                self.server = server
                let url = try await server.start()
                model = ForumBrowserModel(initialURL: url, onNativeNavigation: { handoffs.append($0) })
            } catch { failure = error.localizedDescription }
        }
        .onDisappear { server?.stop() }
    }
}

private final class ForumWebFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "forum.web.fixture")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue.global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let response: String
                if request.hasPrefix("GET /redirect ") {
                    response = "HTTP/1.1 302 Found\r\nLocation: https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    let isPost = request.hasPrefix("POST ")
                    let body = """
                    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Original Web Layout</title>
                    <style>body{font:18px -apple-system;margin:20px}main{display:grid;grid-template-columns:1fr 1fr;gap:16px}.tile{height:120px;padding:16px;background:#afe2cb}.tile+div{background:#ffd978}button,a{display:block;margin:20px 0;padding:12px}button{font:inherit}</style></head>
                    <body><h1>Original Web Layout</h1><main><div class="tile">CSS Left</div><div class="tile">CSS Right</div></main>
                    <button onclick="this.textContent='JavaScript works'">Run JavaScript</button>
                    <p>\(isPost ? "POST stayed in WebView" : "GET page")</p>
                    <form method="post" action="/submit"><button>Submit POST</button></form>
                    <a href="https://bbs.yamibo.com/forum.php?mod=viewthread&amp;tid=123" target="_blank">Native new window</a>
                    <a href="/redirect">Native redirect</a></body></html>
                    """
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    guard let port = self.listener.port else { continuation.resume(throwing: ForumPageError.invalidURL); return }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
                case let .failed(error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
    deinit { listener.cancel() }
}

private struct ImageBrowserFixture: View {
    @Namespace private var zoomNamespace
    @State private var isPresented = false
    private let items: [ImageBrowserItem]

    init() {
        let sizes = [CGSize(width: 401, height: 801), CGSize(width: 803, height: 401), CGSize(width: 601, height: 601)]
        let colors: [UIColor] = [.systemRed, .systemGreen, .systemBlue]
        items = sizes.enumerated().map { index, size in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                colors[index].setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.white.setFill()
                context.fill(CGRect(x: size.width / 4, y: size.height / 4, width: size.width / 2, height: size.height / 2))
                ("\(index + 1)" as NSString).draw(at: CGPoint(x: size.width / 2 - 25, y: size.height / 2 - 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 72), .foregroundColor: UIColor.black])
            }
            return ImageBrowserItem(id: "image-\(index + 1)",
                source: YamiboImageSource(url: URL(fileURLWithPath: "/offline-image-\(index + 1).png")),
                title: "Image \(index + 1)", localDataProvider: { data })
        }
    }

    var body: some View {
        Button("Open gallery") { isPresented = true }
            .imageBrowserZoomSource(id: "image-2", in: zoomNamespace)
            .fullScreenCover(isPresented: $isPresented) {
                let isSingle = ProcessInfo.processInfo.environment["IMAGE_BROWSER_SINGLE"] == "1"
                ImageBrowserView(items: isSingle ? [items[1]] : items, initialItemID: "image-2",
                    mode: isSingle ? .single : .multiple,
                    presentation: ProcessInfo.processInfo.environment["IMAGE_BROWSER_PRESENTATION"] == "fade"
                        ? .fade : .zoom(zoomNamespace),
                    onDismiss: { isPresented = false })
            }
    }
}

private struct CreditLogFixture: View {
    private enum Destination: Hashable {
        case credits
        case link(URL)
    }

    @State private var path: [Destination] = []
    @State private var account = 1

    private let environment = ProcessInfo.processInfo.environment

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                UserSpaceProfileHeaderView(
                    profile: UserSpaceProfile(uid: "1", username: "测试用户", totalPoints: 155, points: 29, partner: 377),
                    isSelf: environment["CREDIT_LOG_OTHER_PROFILE"] != "1",
                    onSectionTap: { _, _ in },
                    beginAddFriend: {},
                    onMessageCenterTap: { _ in },
                    onCreditLogTap: { path.append(.credits) },
                    onWebTap: { path.append(.link($0)) }
                )
                .padding(16)
            }
            .navigationTitle("我的资料")
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .credits:
                    CreditLogView(
                        model: CreditLogViewModel(repository: CreditLogFixtureRepository(
                            account: account,
                            failPageOnce: environment["CREDIT_LOG_FAIL_PAGE"] == "1",
                            emptyExpense: environment["CREDIT_LOG_EMPTY_EXPENSE"] == "1"
                        )),
                        onURLTap: { path.append(.link($0)) }
                    )
                    .id(account)
                    .forumNavigationBarStyle()
                    .toolbar {
                        Button("切换测试账号") { account += 1 }
                            .accessibilityIdentifier("credit-fixture-switch-account")
                    }
                case .link(let url):
                    CreditLogThreadFixture(url: url)
                }
            }
        }
        .forumTheme(.theme(for: AppThemePreset(rawValue: environment["CREDIT_LOG_THEME"] ?? "standard") ?? .standard))
        .preferredColorScheme(environment["CREDIT_LOG_DARK"] == "1" ? .dark : .light)
    }
}

private struct CreditLogThreadFixture: View {
    let url: URL
    @State private var model: ForumThreadReaderViewModel?
    @State private var failure: String?

    var body: some View {
        Group {
            if let model {
                ForumThreadReaderView(model: model, onUserTap: { _, _ in }, onURLTap: { _ in })
            } else if let failure {
                Text(failure)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            do {
                guard case .thread = ForumRouteResolver.resolve(url: url) else { throw ForumPageError.invalidURL }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [CreditLogThreadURLProtocol.self]
                configuration.httpCookieStorage = nil
                let client = YamiboClient(session: URLSession(configuration: configuration))
                let target = try await YamiboThreadRouteResolver(client: client).resolve(.init(threadURL: url, intent: .nativeThreadReader))
                guard case let .thread(payload) = target else { throw ForumPageError.invalidURL }
                let context = ThreadNovelLaunchContext(thread: payload.thread, title: payload.title,
                    initialPage: payload.initialPage, targetPostID: payload.targetPostID)
                let cache = ForumCacheStore(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("credit-thread-\(UUID().uuidString)"))
                model = ForumThreadReaderViewModel(context: context, repository: ForumThreadReaderRepository(client: client, cacheStore: cache))
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private final class CreditLogThreadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: ForumPageError.invalidURL)
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isLocation = items.contains(.init(name: "goto", value: "findpost")) && items.contains(.init(name: "pid", value: "456"))
        let isPage = items.contains(.init(name: "tid", value: "123")) && items.contains(.init(name: "page", value: "3"))
        guard isLocation || isPage else {
            client?.urlProtocol(self, didFailWithError: ForumPageError.invalidURL)
            return
        }
        let responseURL = URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=123&page=3#pid456")!
        let preceding = (441...455).map { pid in
            "<div id='post_\(pid)'><div class='authi'><a class='author' href='home.php?mod=space&amp;uid=42'>测试作者</a><em>发表于 2026-9-11</em></div><div class='message' id='postmessage_\(pid)'>第 \(pid) 条回复<br>定位前的测试正文<br>定位前的测试正文</div></div>"
        }.joined()
        let html = """
        <html><head><title>真实帖子定位夹具</title></head><body>
        \(preceding)
        <div id='post_456'><div class='authi'><a class='author' href='home.php?mod=space&amp;uid=42'>目标作者</a><em>发表于 2026-9-11</em></div>
        <div class='message' id='postmessage_456'>评分对应的目标楼层 456</div></div>
        <div class='pg'><a href='forum.php?mod=viewthread&amp;tid=123&amp;page=1'>1</a><a>2</a><strong>3</strong><span>/ 5 页</span></div>
        </body></html>
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor CreditLogFixtureRepository: CreditLogPageLoading {
    let account: Int
    let emptyExpense: Bool
    var failPageOnce: Bool

    init(account: Int, failPageOnce: Bool, emptyExpense: Bool) {
        self.account = account
        self.failPageOnce = failPageOnce
        self.emptyExpense = emptyExpense
    }

    func fetchCreditLog(filter: CreditLogFilter, page: Int) async throws -> CreditLogPage {
        if page == 2, failPageOnce {
            failPageOnce = false
            throw YamiboError.offline
        }
        if filter == .expense, emptyExpense { return CreditLogPage(entries: []) }
        let threadTitle = "Yamibo X：iOS端的百合会App，提供原生阅读体验与收藏管理"
        let description = ForumThreadTextBlock(
            text: threadTitle,
            links: [ForumThreadTextLink(start: 0, length: threadTitle.count, url: URL(string: "https://bbs.yamibo.com/forum.php?mod=redirect&goto=findpost&pid=456")!)]
        )
        let checkIn = CreditLogEntry(
            id: "check-in-\(account)-\(page)", operation: page == 1 ? "天天打卡" : "第2页记录",
            changes: [CreditLogChange(name: "对象", valueText: "+1", amount: 1)],
            description: ForumThreadTextBlock(text: "账号 \(account)"), timeText: "2026-09-10 00:22"
        )
        let rating = CreditLogEntry(
            id: "rating", operation: "帖子被评分",
            changes: [CreditLogChange(name: "积分", valueText: "+10", amount: 10)],
            description: description, timeText: "2026-09-09 12:52"
        )
        let expense = CreditLogEntry(
            id: "expense", operation: "购买附件",
            changes: [CreditLogChange(name: "积分", valueText: "-3", amount: -3)],
            description: ForumThreadTextBlock(text: "下载附件"), timeText: "2026-09-08 09:10"
        )
        let older = (1...5).map { index in
            CreditLogEntry(
                id: "old-\(index)", operation: "天天打卡",
                changes: [CreditLogChange(name: "对象", valueText: "+2", amount: 2)],
                description: ForumThreadTextBlock(text: "天天打卡"), timeText: "2026-09-0\(7-index) 00:04"
            )
        }
        let entries: [CreditLogEntry]
        switch filter {
        case .all: entries = [checkIn, rating, expense] + older
        case .income: entries = [checkIn, rating] + older
        case .expense: entries = [expense]
        }
        return CreditLogPage(entries: entries, pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 2))
    }
}

private struct ChapterCommentComposerFixture: View {
    @State private var selectedTarget: ReaderChapterCommentComposeTarget?
    @State private var scrollTarget: String?
    @State private var feedback: TransientFeedback?
    @State private var counts = ChapterCommentFixtureCounts()
    @State private var imageBrowserRequest: ForumThreadImageBrowserRequest?
    @State private var showingOriginalPost = false
    @State private var imageCounts: ChapterCommentImageFixtureCounts
    @State private var imagePipeline: YamiboUIImagePipeline
    private let chapter = ReaderChapterCommentTarget(threadID: "123", view: 2, ownerPostID: "456", title: "第十二章 · 风经过的地方", authorID: "42")
    private var showsImages: Bool { ProcessInfo.processInfo.environment["CHAPTER_COMMENT_IMAGES"] == "1" }
    private var isNovel: Bool { ProcessInfo.processInfo.environment["CHAPTER_COMMENT_READER"] != "manga" }
    private var placement: ReaderChapterReplyPlacement {
        switch ProcessInfo.processInfo.environment["CHAPTER_COMMENT_BOUNDARY"] {
        case "latest": .withinChapter
        case "unknown": .unknown
        default: .outsideChapter
        }
    }

    init() {
        let imageCounts = ChapterCommentImageFixtureCounts()
        _imageCounts = State(initialValue: imageCounts)
        _imagePipeline = State(initialValue: YamiboUIImagePipeline(core: ChapterCommentFixtureImageLoader(
            images: ["one.png": Self.imageData(color: .systemRed, title: "FIRST"), "two.png": Self.imageData(color: .systemGreen, title: "SECOND")],
            counts: imageCounts
        )))
    }

    private var comments: [ChapterComment] {
        if showsImages {
            return [
                ChapterComment(id: "photos", source: .postComment, authorName: "远山", metadata: "2026-09-10 12:30", body: "第一张之前。两张之间。第二张之后。", postID: "456", contentBlocks: [
                    .init(id: "before", kind: .text(.init(text: "第一张之前。"))), imageBlock("one", title: "第一张"),
                    .init(id: "between", kind: .text(.init(text: "两张之间。"))), imageBlock("two", title: "第二张"),
                    .init(id: "after", kind: .text(.init(text: "第二张之后。")))
                ]),
                ChapterComment(id: "failed", source: .ratingReason, authorName: "夏木", metadata: "积分 +2", body: "", postID: "456", contentBlocks: [imageBlock("missing", title: "加载失败测试")]),
                ChapterComment(id: "reply", source: .reply, authorName: "见微", metadata: "28楼 · 2026-09-10 14:20", body: "最后那句让我想起第一章的约定，期待她们再见面。", postID: "789")
            ]
        }
        return [
            ChapterComment(id: "comment", source: .postComment, authorName: "远山", metadata: "2026-09-10 12:30", body: "读到这里，终于明白她为什么一直没有离开。", postID: "456", authorAvatarURL: URL(string: "https://bbs.yamibo.com/uc_server/data/avatar/000/70/52/16_avatar_middle.jpg")),
            ChapterComment(id: "rating", source: .ratingReason, authorName: "夏木", metadata: "积分 +2", body: "这一章的对话写得真好。", postID: "456", authorAvatarURL: URL(string: "https://avatar.invalid/missing.jpg")),
            ChapterComment(id: "reply", source: .reply, authorName: "见微", metadata: "28楼 · 2026-09-10 14:20", body: "最后那句让我想起第一章的约定，期待她们再见面。", postID: "789")
        ]
    }

    private func imageBlock(_ name: String, title: String) -> ForumThreadContentBlock {
        .init(id: name, kind: .image(.init(url: URL(string: "https://chapter-images.invalid/\(name).png")!, altText: title)))
    }

    private static func imageData(color: UIColor, title: String) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            (title as NSString).draw(at: CGPoint(x: 80, y: 270), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 70), .foregroundColor: UIColor.white])
        }
    }

    var body: some View {
        NavigationStack {
            ReaderChapterCommentsContent(
                state: .loaded(chapter, ChapterCommentsPage(target: chapter, comments: comments, isBoundaryClosed: placement == .outsideChapter)),
                isLoadingMore: false, loadMoreError: nil, refreshError: nil, scrollTarget: $scrollTarget,
                retry: { _ in }, loadNext: {}, openOriginalPost: { _ in showingOriginalPost = true }, compose: { selectedTarget = $0 },
                openImage: { comment, blockID in
                    imageBrowserRequest = ReaderChapterCommentImageGallery.request(comment: comment, target: chapter, selectedBlockID: blockID)
                }
            )
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    ReaderChapterCommentComposeBar { selectedTarget = ReaderChapterCommentComposeTarget.owner(chapter) }
                    if showsImages {
                        Text(verbatim: "loads=\(imageCounts.loads)")
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                            .background(.background)
                            .accessibilityIdentifier("chapter-image-loads")
                    }
                }
            }
            .navigationTitle("章节评论")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottomTrailing) {
                if !showsImages {
                    Text(verbatim: "count=\(counts.submissions);mode=\(counts.mode);pid=\(counts.postID);page=\(counts.page);uploads=\(counts.uploads)")
                    .font(.caption2)
                    .accessibilityIdentifier("chapter-comment-diagnostics")
                    .allowsHitTesting(false)
                }
            }
        }
        .sheet(item: $selectedTarget) { target in
            ReaderChapterCommentComposerSheet(
                model: ReaderChapterCommentComposerModel(target: target, actions: fixtureActions),
                replyPlacement: placement, isNovel: isNovel, onSubmitted: { feedback = $0 }
            ) { _ in
                ChapterCommentFixtureDestination()
            }
            .environment(\.dynamicTypeSize, ProcessInfo.processInfo.environment["CHAPTER_COMMENT_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
        }
        .fullScreenCover(item: $imageBrowserRequest) { request in
            ImageBrowserView(items: request.items, initialItemID: request.initialItemID,
                             mode: request.items.count == 1 ? .single : .multiple) { imageBrowserRequest = nil }
        }
        .sheet(isPresented: $showingOriginalPost) { ChapterCommentFixtureDestination() }
        .transientMessage(feedback) { feedback = nil }
        .environment(\.yamiboImagePipeline, showsImages ? imagePipeline : nil)
        .appTheme(.theme(for: .standard))
        .preferredColorScheme(ProcessInfo.processInfo.environment["CHAPTER_COMMENT_DARK"] == "1" ? .dark : .light)
        .dynamicTypeSize(ProcessInfo.processInfo.environment["CHAPTER_COMMENT_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
    }

    private var fixtureActions: ReaderChapterCommentComposeActions {
        ReaderChapterCommentComposeActions(loadContext: { tid, pid in
            if ProcessInfo.processInfo.environment["CHAPTER_COMMENT_CONTEXT_FAIL"] == "1" { throw YamiboError.notAuthenticated }
            try ChapterCommentFixtureFailure.check("CHAPTER_COMMENT_CONTEXT_FAIL")
            return ForumPostActionContext(threadID: tid, post: ForumThreadPost(postID: pid,
                author: .init(uid: pid == "456" ? "42" : "77", name: pid == "456" ? "南枝" : "见微"), contentHTML: "", contentText: "正文"), page: 9, formHash: "offline")
        }, loadRateOptions: { _, _ in
            try ChapterCommentFixtureFailure.check("CHAPTER_COMMENT_RATE_FAIL")
            return .init(availableScores: [-1, 1, 2, 5], defaultReasons: ["好文", "谢谢分享"])
        }, rate: { context, _, _, _ in
            try await counts.submit(mode: "rating", pid: context.post.postID, page: context.page)
            return "评分成功"
        }, comment: { context, _ in
            try await counts.submit(mode: "comment", pid: context.post.postID, page: context.page)
            return "点评成功"
        }, makeReplySession: { url in
            let form = ForumForm(id: "postform", title: "回复", actionURL: url, kind: .thread,
                fields: [.init(id: "message", name: "message", label: "回复内容", kind: .multiline,
                               initialValues: ["[quote]她推开窗，风穿过长长的走廊。[/quote]\n"], isRequired: true)],
                hiddenValues: [.init(name: "formhash", value: "offline")], buttons: [.init(id: "send", title: "发表回复")])
            let uploads = [
                ForumUploadConfiguration(id: "image", url: url, kind: .threadImage, values: [], maximumBytes: 5 * 1_024 * 1_024, extensions: ["jpg", "png"]),
                ForumUploadConfiguration(id: "attachment", url: url, kind: .threadAttachment, values: [], maximumBytes: 5 * 1_024 * 1_024, extensions: ["txt", "pdf"])
            ]
            let page = ForumPageDocument(url: url, title: "发表回复", forms: [form], uploads: uploads)
            return ForumPageSession(url: url, repository: ChapterCommentFixtureReplyRepository(page: page, counts: counts))
        })
    }
}

private enum ChapterCommentFixtureFailure {
    static func check(_ key: String) throws {
        switch ProcessInfo.processInfo.environment[key] {
        case "auth": throw YamiboError.notAuthenticated
        case "offline": throw URLError(.notConnectedToInternet)
        case "own":
            _ = try ForumThreadPageHTMLParser.parseRateOptions(from: "<div class='messagetext'><p>抱歉，您不能给自己发表的帖子评分</p></div>")
        default: break
        }
    }
}

@MainActor @Observable private final class ChapterCommentImageFixtureCounts {
    var loads = 0
}

private struct ChapterCommentFixtureImageLoader: YamiboImageDataLoading {
    let images: [String: Data]
    let counts: ChapterCommentImageFixtureCounts

    func data(for source: YamiboImageSource) async throws -> Data {
        await MainActor.run { counts.loads += 1 }
        guard let data = images[source.url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
        return data
    }

    func cachedData(for source: YamiboImageSource) -> Data? { nil }
}

private struct ChapterCommentFixtureDestination: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Text("Offline destination")
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}

@MainActor @Observable private final class ChapterCommentFixtureCounts {
    var submissions = 0
    var mode = "none"
    var postID = "none"
    var page = 0
    var uploads = 0

    func submit(mode: String, pid: String, page: Int) async throws {
        submissions += 1
        self.mode = mode
        self.postID = pid
        self.page = page
        try await Task.sleep(for: .milliseconds(300))
        try ChapterCommentFixtureFailure.check("CHAPTER_COMMENT_SEND_FAIL")
        if ProcessInfo.processInfo.environment["CHAPTER_COMMENT_SEND_FAIL"] == "1", submissions == 1 {
            throw NSError(domain: "OfflineChapterFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline submission failed"])
        }
    }
}

private actor ChapterCommentFixtureReplyRepository: ForumPageLoading {
    let page: ForumPageDocument
    let counts: ChapterCommentFixtureCounts
    init(page: ForumPageDocument, counts: ChapterCommentFixtureCounts) { self.page = page; self.counts = counts }
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult {
        try ChapterCommentFixtureFailure.check("CHAPTER_COMMENT_REPLY_FAIL")
        return .page(page)
    }
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        try await counts.submit(mode: "reply", pid: page.url.queryItemValue("repquote") ?? "", page: Int(page.url.queryItemValue("page") ?? "") ?? 0)
        return .page(ForumPageDocument(url: page.url, title: "Offline Result", message: "回复发表成功"))
    }
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        await MainActor.run { counts.uploads += 1 }
        return ForumUploadedAttachment(id: "999", name: file.name, markup: "[attach]999[/attach]", values: [])
    }
}

private struct ForumPhotoUploadFixture: View {
    @State private var model: ForumPageSession
    @State private var counts: ForumPhotoUploadCounts

    init(attachmentFixture: Bool = false) {
        if attachmentFixture {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try! FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try! Data("Offline attachment fixture.\n".utf8).write(to: documents.appendingPathComponent("offline-attachment.txt"), options: .atomic)
        }
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=123&mobile=2")!
        let html = """
        <html><head><title>Offline Photo Upload</title></head><body>
        <form id="postform" method="post" action="forum.php?mod=post&amp;action=reply&amp;tid=123&amp;replysubmit=yes&amp;mobile=2">
        <input type="hidden" name="formhash" value="offline-fixture">
        <textarea name="message" id="message">Offline photo draft</textarea>
        <button type="submit" name="replysubmit" value="yes">Send Reply</button>
        </form></body></html>
        """
        let parsed = try! ForumFormPageParser.parse(html: html, url: url)
        let configurations = attachmentFixture ? [
            ForumUploadConfiguration(id: "offline-attachment", url: url, kind: .threadAttachment, values: [], maximumBytes: 5 * 1_024 * 1_024, extensions: ["txt", "pdf", "jpg"])
        ] : [
            ForumUploadConfiguration(id: "offline-image", url: url, kind: .threadImage, values: [], maximumBytes: 5 * 1_024 * 1_024, extensions: ["jpg", "jpeg", "png", "gif"]),
            ForumUploadConfiguration(id: "offline-attachment", url: url, kind: .threadAttachment, values: [], maximumBytes: 5 * 1_024 * 1_024, extensions: ["jpg", "jpeg", "png", "gif"])
        ]
        let page = ForumPageDocument(url: url, title: parsed.title, forms: parsed.forms, uploads: configurations)
        let counts = ForumPhotoUploadCounts()
        _counts = State(wrappedValue: counts)
        _model = State(wrappedValue: ForumPageSession(url: url, repository: ForumPhotoUploadRepository(page: page, counts: counts)))
    }

    var body: some View {
        NavigationStack {
            ForumPageScreen(model: model, onURLTap: { _ in })
                .forumNavigationBarStyle()
                .safeAreaInset(edge: .bottom) {
                    Text(verbatim: "uploads=\(counts.uploads);mime=\(counts.mimeType);bytes=\(counts.byteCount)")
                        .font(.caption2)
                        .accessibilityIdentifier("forum-photo-upload-diagnostics")
                }
        }
    }
}

@MainActor @Observable private final class ForumPhotoUploadCounts {
    var uploads = 0
    var mimeType = "none"
    var byteCount = 0
}

private actor ForumPhotoUploadRepository: ForumPageLoading {
    let page: ForumPageDocument
    let counts: ForumPhotoUploadCounts

    init(page: ForumPageDocument, counts: ForumPhotoUploadCounts) {
        self.page = page
        self.counts = counts
    }

    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult { .page(page) }

    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        throw NSError(domain: "OfflinePhotoFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Posting is disabled in the photo fixture"])
    }

    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        await MainActor.run {
            counts.uploads += 1
            counts.mimeType = mimeType
            counts.byteCount = file.data.count
        }
        let markup = configuration.kind == .threadAttachment ? "[attach]999001[/attach]" : "[attachimg]999001[/attachimg]"
        return ForumUploadedAttachment(id: "999001", name: file.name, markup: markup, values: [])
    }
}

private struct ForumSendCrashFixture: View {
    @State private var model: ForumPageSession
    @State private var counts: ForumSendCrashCounts
    @State private var showsComposer = false
    @State private var feedback: TransientFeedback?

    init() {
        let action = ProcessInfo.processInfo.environment["FORUM_SEND_ACTION"] ?? "reply"
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=\(action)&tid=123&pid=456&mobile=2")!
        let source = ProcessInfo.processInfo.environment["FORUM_SEND_INITIAL_SOURCE"] ?? ""
        let firstPost = ProcessInfo.processInfo.environment["FORUM_SEND_FIRST_POST"] == "1"
        let options = ProcessInfo.processInfo.environment["FORUM_COMPOSER_OPTIONS_FIXTURE"] == "1" ? """
        <input type="checkbox" name="usesig" value="1" checked>
        <input name="tags" value="fixture-tags">
        """ : ""
        let html = """
        <html><head><title>Offline Reply</title></head><body>
        <script>var isfirstpost = \(firstPost ? "1" : "0");</script>
        <form id="postform" method="post" action="forum.php?mod=post&amp;action=\(action)&amp;tid=123&amp;pid=456&amp;replysubmit=yes&amp;mobile=2">
        <input type="hidden" name="formhash" value="offline-fixture">
        <input type="text" name="subject" id="needsubject" value="Offline Subject">
        <textarea name="message" id="message">\(source)</textarea>
        \(options)
        <button type="submit" name="replysubmit" value="yes">Send Reply</button>
        </form></body></html>
        """
        let page = try! ForumFormPageParser.parse(html: html, url: url)
        let counts = ForumSendCrashCounts()
        _counts = State(wrappedValue: counts)
        _model = State(wrappedValue: ForumPageSession(url: url, repository: ForumSendCrashRepository(page: page, counts: counts)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Offline Previous Page")
                    .accessibilityIdentifier("forum-feedback-previous-page")
                Button("Open Editor") { showsComposer = true }
                    .accessibilityIdentifier("forum-feedback-open-editor")
                diagnostics
            }
            .navigationTitle("Offline Thread")
            .navigationDestination(isPresented: $showsComposer) {
                ForumPageScreen(model: model, onSubmissionSucceeded: { feedback = $0 }, onURLTap: { _ in })
                    .forumNavigationBarStyle()
                    .safeAreaInset(edge: .bottom) { diagnostics }
            }
        }
        .transientMessage(feedback) { feedback = nil }
    }

    private var diagnostics: some View {
        Text(verbatim: "pending=\(model.pendingSubmission != nil);submitting=\(model.isSubmitting);success=\(model.submissionSucceeded);count=\(counts.submissions)\(optionsDiagnostics)")
            .font(.caption2)
            .accessibilityIdentifier("forum-send-diagnostics")
    }

    private var optionsDiagnostics: String {
        guard let form = model.page?.forms.first,
              let field = form.fields.first(where: { $0.name == "usesig" }) else { return "" }
        let values = model.drafts[form.id]?[field.id] ?? field.initialValues
        let prepared = model.pendingSubmission?.values[field.id].map { String(!$0.isEmpty) } ?? "none"
        return ";signature=\(!values.isEmpty);preparedSignature=\(prepared)"
    }
}

@MainActor @Observable private final class ForumSendCrashCounts {
    var submissions = 0
}

private actor ForumSendCrashRepository: ForumPageLoading {
    let page: ForumPageDocument
    let counts: ForumSendCrashCounts
    init(page: ForumPageDocument, counts: ForumSendCrashCounts) { self.page = page; self.counts = counts }
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult { .page(page) }
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL, files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        let attempt = await MainActor.run { counts.submissions += 1; return counts.submissions }
        try await Task.sleep(for: .seconds(1))
        if ProcessInfo.processInfo.environment["FORUM_SEND_FAIL"] == "1", attempt == 1 {
            throw NSError(domain: "OfflineFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline submission failed"])
        }
        return .page(ForumPageDocument(url: page.url, title: "Offline Result", message: "Offline submission captured 发表成功"))
    }
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        throw ForumPageError.unsupportedUpload
    }
}

private struct MangaLongPressFixture: View {
    @State private var surface = MangaSurfaceAttachment()
    @State private var menuCount = 0
    private let image: UIImage

    init() {
        let width = Double(ProcessInfo.processInfo.environment["MANGA_TEST_IMAGE_WIDTH"] ?? "400") ?? 400
        let size = CGSize(width: width, height: 800)
        image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            MangaPagedReaderScaledImage(
                image: image, pageID: "layout", pageScaleMode: .fitHeight,
                initialHorizontalAlignment: .left, pageEdgeFillStyle: .system,
                isSurfaceInteractionEnabled: true, isZoomInteractionEnabled: true,
                allowsUnzoomedSurfacePan: true, surfaceInteraction: surface,
                onLongPress: { menuCount += 1 }
            )
            .frame(width: 400, height: 800)

            Text(diagnostics)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black)
                .accessibilityIdentifier("manga-diagnostics")
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var diagnostics: String {
        let runtime = surface.runtime
        let values: [String: Double] = [
            "count": Double(menuCount),
            "loaded": runtime.imageLoaded ? 1 : 0,
            "viewportWidth": runtime.geometry.viewport.width,
            "viewportHeight": runtime.geometry.viewport.height,
            "menuMidX": runtime.menuFrame.midX,
            "menuWidth": runtime.menuFrame.width,
            "offsetX": runtime.transform.offset.width
        ]
        guard let data = try? JSONEncoder().encode(values) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

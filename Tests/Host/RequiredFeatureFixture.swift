import Observation
import SwiftUI
@testable import YamiboXCore
@testable import YamiboXUI

/// Isolated real stores and workflows, never missing production capabilities.
final class RequiredFeatureFixtureServices: Sendable {
    let context: YamiboAppContext

    init() {
        let suite = "required-features-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequiredFeatureOfflineURLProtocol.self]
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: UserDefaults(suiteName: suite)!),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suite)!),
            webDAVSyncSettingsStore: WebDAVSyncSettingsStore(defaults: UserDefaults(suiteName: suite)!),
            readerResumeRouteStore: ReaderResumeRouteStore(defaults: UserDefaults(suiteName: suite)!),
            grdbRootDirectory: root,
            cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: UserDefaults(suiteName: suite)!,
            clearsWebDataOnReset: false,
            session: URLSession(configuration: configuration),
            imageSession: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func pageSession(url: URL, repository: any ForumPageLoading) -> ForumPageSession {
        ForumPageSession(
            url: url, repository: repository,
            sessionStore: context.forumDependencies.sessionStore,
            draftStore: context.forumDependencies.composerDraftStore
        )
    }
}

private final class RequiredFeatureOfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

struct RequiredFeatureFixture: View {
    @State private var model = RequiredFeatureFixtureModel()
    private let scenario = ProcessInfo.processInfo.environment["REQUIRED_FEATURE_FIXTURE"] ?? "history"

    var body: some View {
        NavigationStack {
            Form {
                if scenario == "history" {
                    Text(model.historyStatus).accessibilityIdentifier("required-history")
                    action("Record visit", id: "record") { try await model.recordVisit() }
                    action("Switch reader mode", id: "mode") { try await model.switchMode() }
                    action("Delete and save progress", id: "delete") { try await model.deleteAndSaveProgress() }
                    action("Load preview", id: "preview") { try await model.loadPreview() }
                } else if scenario == "messages" {
                    Text("unread=\(model.unread.totalCount); requests=\(model.requestCount); \(model.messageStatus)")
                        .accessibilityIdentifier("required-messages")
                    action("Guest refresh", id: "guest") { await model.guestRefresh() }
                    action("Sign in", id: "signin") { try await model.signIn() }
                    action("Read messages", id: "read") { await model.readMessages() }
                    action("Start delayed refresh", id: "delay") { await model.startDelayedRefresh() }
                    action("Switch account", id: "switch") { try await model.switchMessageAccount() }
                } else {
                    Text(model.draftStatus).accessibilityIdentifier("required-draft")
                    if let session = model.draftSession, let form = session.page?.forms.first {
                        TextField("Draft text", text: Binding(
                            get: { session.drafts[form.id]?["message"]?.first ?? "" },
                            set: { session.drafts[form.id, default: [:]]["message"] = [$0] }
                        ))
                        .accessibilityIdentifier("required-draft-text")
                    }
                    action("Open signed-in editor", id: "editor") { try await model.openEditor() }
                    action("Attach and save", id: "save") { try await model.saveDraft() }
                    action("Reopen saved draft", id: "reopen") { await model.reopenDraft() }
                    action("Submit with failure", id: "fail") { await model.failSubmission() }
                    action("Switch draft account", id: "switch-draft") { try await model.switchDraftAccount() }
                    action("Open guest editor", id: "guest-editor") { try await model.openGuestEditor() }
                    action("Open non-post form", id: "standard") { try await model.openStandardForm() }
                }
                Text(model.error ?? "").accessibilityIdentifier("required-error")
                Text(model.busy ? "busy" : "ready").accessibilityIdentifier("required-ready")
            }
            .navigationTitle("Required dependencies")
        }
    }

    private func action(_ title: String, id: String, operation: @escaping @MainActor () async throws -> Void) -> some View {
        Button(title) {
            Task {
                model.busy = true
                model.error = nil
                defer { model.busy = false }
                do { try await operation() } catch { model.error = String(describing: error) }
            }
        }
        .accessibilityIdentifier("required-\(id)")
        .disabled(model.busy)
    }
}

@MainActor @Observable
private final class RequiredFeatureFixtureModel {
    let services = RequiredFeatureFixtureServices()
    let unread: MessageUnreadWorkflow
    private let server = RequiredMessageServer()
    private var pendingRefresh: Task<Void, Never>?
    private var savedDraft: ForumComposerDraft?
    var busy = false
    var error: String?
    var historyStatus = "home=0; history=0"
    var messageStatus = ""
    var requestCount = 0
    var draftStatus = "closed"
    var draftSession: ForumPageSession?

    init() {
        let server = server
        unread = MessageUnreadWorkflow(sessionStore: services.context.forumDependencies.sessionStore) {
            RequiredUnreadLoader(server: server, uid: $0.accountUID ?? "")
        }
    }

    private var context: YamiboAppContext { services.context }
    private var sessionStore: SessionStore { context.forumDependencies.sessionStore }

    private func setAccount(_ uid: String?) async throws {
        try await sessionStore.save(uid.map {
            SessionState(cookie: "\(SessionState.authenticationCookieName)=fixture-\($0)", isLoggedIn: true, accountUID: $0)
        } ?? SessionState())
    }

    func recordVisit() async throws {
        try await context.settingsStore.update {
            $0.system.homeShowsOnlyFavorites = false
            $0.boardReader.entries["49"] = .init(mode: .novel)
        }
        try await context.browsingHistoryWorkflow.recordVisit(.init(threadID: "9001", title: "Shared book", forumID: "49", reader: .novel))
        await refreshHistory()
    }

    private func refreshHistory(suffix: String = "") async {
        let home = ReadingHomeViewModel(dependencies: context.libraryDependencies)
        let history = BrowsingHistoryViewModel(dependencies: context.libraryDependencies)
        await home.reload()
        await history.reload()
        let books = home.continuing + home.previous
        let sameIDs = Set(books.map(\.id)) == Set(history.entries.map(\.id))
        historyStatus = "home=\(books.count); history=\(history.entries.count); same=\(sameIDs); \(suffix)"
    }

    func switchMode() async throws {
        let oldEntry = try await context.browsingHistoryWorkflow.snapshot().entries.first!
        try await context.settingsStore.update { $0.boardReader.entries["49"] = .init(mode: .manga(smartEnabled: false)) }
        let resolver = ReadingOpenTargetResolver(
            readingProgressStore: context.readingProgressStore,
            mangaDirectoryStore: context.libraryDependencies.mangaDirectoryStore,
            historyWorkflow: context.browsingHistoryWorkflow
        )
        let target = await resolver.openTarget(for: oldEntry)
        let route: String
        switch target {
        case .mangaReader: route = "manga"
        case .novelReader: route = "novel"
        case .nativeThread: route = "thread"
        case nil: route = "missing"
        }
        await refreshHistory(suffix: "route=\(route)")
    }

    func deleteAndSaveProgress() async throws {
        let history = BrowsingHistoryViewModel(dependencies: context.libraryDependencies)
        await history.reload()
        if let entry = history.entries.first { await history.delete(entry) }
        try await FavoriteLibraryProgressSyncAdapter(
            readingProgressStore: context.readingProgressStore,
            browsingHistoryWorkflow: context.browsingHistoryWorkflow
        ).saveNovelReadingPosition(.init(threadID: "9001", view: 2))
        await refreshHistory(suffix: "deleted")
    }

    func loadPreview() async throws {
        let thread = ThreadIdentity(tid: "9002", fid: "49")
        let page = ForumThreadPage(thread: thread, title: "Preview book", posts: [
            .init(postID: "9002-1", author: .init(uid: "42", name: "Author"),
                  contentHTML: "<p>第一章</p><p>这是不会写入历史的预览内容。</p>", contentText: "第一章 这是不会写入历史的预览内容。")
        ], pageNavigation: .init(currentPage: 1, totalPages: 1))
        try await context.forumCacheStore.saveThreadPage(page, thread: thread, pageNumber: 1, authorID: nil)
        try await context.forumCacheStore.saveThreadPage(page, thread: thread, pageNumber: 1, authorID: "42")
        let reader = NovelReaderViewModel(
            context: .init(threadID: thread.tid, threadTitle: page.title, source: .forum, authorID: "42", isPreview: true, forumID: "49"),
            dependencies: context.novelReaderDependencies
        )
        await reader.prepare(layout: .init(width: 400, height: 700))
        if let failure = reader.errorMessage { throw YamiboError.underlying(failure) }
        let loaded = reader.novelReaderPresentation != nil
        _ = await reader.saveProgress()
        reader.close()
        let progress = await context.readingProgressStore.load(for: .novelThread(threadID: thread.tid))
        await refreshHistory(suffix: "previewLoaded=\(loaded); previewProgress=\(progress != nil)")
    }

    func guestRefresh() async {
        await unread.appDidBecomeActive()
        requestCount = await server.requestCount
        messageStatus = "guest"
    }

    func signIn() async throws {
        try await setAccount("1")
        await unread.appDidBecomeActive()
        requestCount = await server.requestCount
        messageStatus = "signed-in"
    }

    func readMessages() async {
        let page = MessageCenterViewModel(repository: server, messageUnreadWorkflow: unread)
        await page.load()
        await unread.refresh(force: true)
        requestCount = await server.requestCount
        messageStatus = page.content == nil ? "load-failed" : "read"
    }

    func startDelayedRefresh() async {
        await server.holdNextRequest()
        pendingRefresh = Task { await unread.refresh(force: true) }
        await server.waitUntilPending()
        requestCount = await server.requestCount
        messageStatus = "pending"
    }

    func switchMessageAccount() async throws {
        unread.prepareForAccountChange()
        try await setAccount("2")
        await unread.refresh(force: true)
        await server.releasePending()
        await pendingRefresh?.value
        requestCount = await server.requestCount
        messageStatus = "switched"
    }

    private func makeEditor(kind: ForumForm.Kind = .thread) async -> ForumPageSession {
        let repository = RequiredDraftRepository(kind: kind)
        let session = services.pageSession(url: repository.page.url, repository: repository)
        await session.load(confirmedAction: true)
        return session
    }

    func openEditor() async throws {
        try await setAccount("1")
        draftSession = await makeEditor()
        await refreshDraft()
    }

    func saveDraft() async throws {
        guard let session = draftSession, let form = session.page?.forms.first else { return }
        await session.stageFormFile(.init(fieldName: "attachment", file: .init(name: "draft.txt", data: Data("persisted attachment".utf8)), mimeType: "text/plain"), form: form)
        let saved = await session.flushLocalDraft(force: true)
        savedDraft = session.composerDraft.current
        await refreshDraft(suffix: "saved=\(saved)")
    }

    func reopenDraft() async {
        draftSession = await makeEditor()
        if let savedDraft { await draftSession?.restoreDraft(savedDraft) }
        await refreshDraft(suffix: "reopened")
    }

    func failSubmission() async {
        guard let session = draftSession, let form = session.page?.forms.first, let button = form.buttons.first else { return }
        session.prepareSubmission(form: form, button: button)
        if let submission = session.pendingSubmission { await session.confirmSubmission(submission) }
        await refreshDraft(suffix: "failed=\(session.errorMessage != nil)")
    }

    func switchDraftAccount() async throws {
        try await ForumComposerDraftCoordinator.prepareForAccountChange(sessionStore: sessionStore)
        try await setAccount("2")
        ForumComposerDraftCoordinator.finishAccountChange(sessionStore: sessionStore)
        draftSession = await makeEditor()
        await refreshDraft(suffix: "account=2")
    }

    func openGuestEditor() async throws {
        try await setAccount(nil)
        draftSession = await makeEditor()
        await refreshDraft(suffix: "guest")
    }

    func openStandardForm() async throws {
        try await setAccount("1")
        draftSession = await makeEditor(kind: .standard)
        await refreshDraft(suffix: "standard")
    }

    private func refreshDraft(suffix: String = "") async {
        guard let session = draftSession else { return }
        let coordinator = session.composerDraft
        await coordinator.reloadList()
        var resource = ""
        if let id = session.composerAssets.first?.resourceID,
           let file = try? await coordinator.resource(id) {
            resource = String(decoding: file.data, as: UTF8.self)
        }
        draftStatus = "active=\(coordinator.active); drafts=\(coordinator.available.count); attachments=\(session.composerAssets.count); resource=\(resource); \(suffix)"
    }
}

private struct RequiredUnreadLoader: MessageUnreadLoading {
    let server: RequiredMessageServer
    let uid: String
    func fetchUnreadSummary() async throws -> MessageUnreadSummary { await server.summary(uid: uid) }
}

private actor RequiredMessageServer: MessageCenterPageLoading {
    private(set) var requestCount = 0
    private var firstAccountCount = 3
    private var holdsNext = false
    private var pending: CheckedContinuation<MessageUnreadSummary, Never>?
    private var pendingWaiter: CheckedContinuation<Void, Never>?

    func summary(uid: String) async -> MessageUnreadSummary {
        requestCount += 1
        if holdsNext {
            holdsNext = false
            return await withCheckedContinuation {
                pending = $0
                pendingWaiter?.resume()
                pendingWaiter = nil
            }
        }
        return .init(privateMessageCount: uid == "1" ? firstAccountCount : 1, noticeCount: 0)
    }

    func holdNextRequest() { holdsNext = true }
    func waitUntilPending() async {
        if pending != nil { return }
        await withCheckedContinuation { pendingWaiter = $0 }
    }
    func releasePending() {
        pending?.resume(returning: .init(privateMessageCount: 9, noticeCount: 0))
        pending = nil
    }
    func fetchPrivateMessages(page: Int) async throws -> UserSpacePrivateMessagePage {
        firstAccountCount = 0
        return .init(messages: [])
    }
    func fetchNotices(page: Int) async throws -> UserSpaceNoticePage { .init(notices: []) }
}

private struct RequiredDraftRepository: ForumPageLoading {
    let page: ForumPageDocument
    init(kind: ForumForm.Kind) {
        let url = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=9001")!
        let form = ForumForm(id: "required-post", title: "Draft", actionURL: url, kind: kind,
                             fields: [.init(id: "message", name: "message", label: "Text", kind: .multiline),
                                      .init(id: "attachment", name: "attachment", label: "File", kind: .file)],
                             buttons: [.init(id: "submit", title: "Submit")])
        page = .init(url: url, title: "Draft", forms: [form],
                     composerContext: .init(target: .init(kind: .reply, threadID: "9001")))
    }
    func fetchPage(url: URL, confirmedAction: Bool) async throws -> ForumPageLoadResult { .page(page) }
    func submit(form: ForumForm, values: [String: [String]], buttonID: String, referer: URL,
                files: [ForumFormFile], attachments: [ForumUploadedAttachment]) async throws -> ForumPageLoadResult {
        throw YamiboError.underlying("Fixture submission failed")
    }
    func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration,
                referer: URL) async throws -> ForumUploadedAttachment {
        throw ForumPageError.unsupportedUpload
    }
}

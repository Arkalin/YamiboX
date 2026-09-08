import Foundation
import Testing
import YamiboXTestSupport
@testable import YamiboXCore
@testable import YamiboXUI

@Suite("Message unread integration")
@MainActor
struct MessageUnreadIntegrationTests {
    @Test func appContextSharesOneWorkflowAcrossEntryPoints() throws {
        let fixture = try makeSystemSettingsFixture()
        let context = fixture.appContext
        #expect(context.accountDependencies.messageUnreadWorkflow === context.messageUnreadWorkflow)
        #expect(context.forumDependencies.messageUnreadWorkflow === context.messageUnreadWorkflow)
    }

    @Test func messageCenterLoadsAndPaginationRefreshGlobalSummaryNotPageCount() async throws {
        try await withWorkflow { workflow, unread in
            let model = MessageCenterViewModel(repository: UnreadMessagePages(), messageUnreadWorkflow: workflow)
            await unread.setCount(4)
            await model.load()
            try await settle(workflow, loader: unread, calls: 2)
            #expect(workflow.totalCount == 4)
            #expect(model.errorMessage == nil)

            await model.goToPage(2)
            try await settle(workflow, loader: unread, calls: 3)
            #expect(workflow.totalCount == 4)
            if case let .privateMessages(page) = model.content {
                #expect(page.unreadCount == 999)
            } else { Issue.record("Expected PM page") }

            await unread.setCount(0)
            await model.selectTab(.notices)
            try await settle(workflow, loader: unread, calls: 4)
            #expect(workflow.totalCount == 0)
        }
    }

    @Test func conversationReadAndSendRefreshBadgesWithoutBlockingContent() async throws {
        try await withWorkflow { workflow, unread in
            let model = PrivateMessageViewModel(
                uid: "42", titleHint: "Test", repository: UnreadMessagePages(), messageUnreadWorkflow: workflow
            )
            await unread.setCount(2)
            await model.load()
            try await settle(workflow, loader: unread, calls: 2)
            #expect(workflow.totalCount == 2)
            #expect(model.page != nil)
            #expect(!model.isLoading)

            await unread.setCount(0)
            model.inputText = "reply"
            await model.send()
            try await settle(workflow, loader: unread, calls: 3)
            #expect(workflow.totalCount == 0)
            #expect(model.inputText.isEmpty)
            #expect(model.errorMessage == nil)
        }
    }

    @Test func failedUnreadCheckDoesNotBecomeMessageCenterError() async throws {
        try await withWorkflow { workflow, unread in
            await unread.failNextCheck()
            let model = MessageCenterViewModel(repository: UnreadMessagePages(), messageUnreadWorkflow: workflow)
            await model.load()
            try await settle(workflow, loader: unread, calls: 2)
            #expect(model.content != nil)
            #expect(model.errorMessage == nil)
            #expect(!model.isLoading)
            #expect(workflow.totalCount == 7)
        }
    }

    private func settle(_ workflow: MessageUnreadWorkflow, loader: IntegrationUnreadLoader, calls: Int) async throws {
        try await waitForCondition { await loader.calls >= calls }
        await workflow.refresh()
    }

    private func withWorkflow(body: (MessageUnreadWorkflow, IntegrationUnreadLoader) async throws -> Void) async throws {
        let name = "MessageUnreadIntegrationTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SessionStore(defaults: defaults)
        try await store.save(SessionState(cookie: "\(SessionState.authenticationCookieName)=test", isLoggedIn: true, accountUID: "1"))
        let loader = IntegrationUnreadLoader()
        let workflow = MessageUnreadWorkflow(sessionStore: store, makeRepository: { _ in loader })
        await workflow.appDidBecomeActive()
        defer { workflow.appDidEnterBackground() }
        try await body(workflow, loader)
    }
}

private actor IntegrationUnreadLoader: MessageUnreadLoading {
    private(set) var calls = 0
    private var count = 7
    private var shouldFail = false
    func setCount(_ count: Int) { self.count = count }
    func failNextCheck() { shouldFail = true }
    func fetchUnreadSummary() async throws -> MessageUnreadSummary {
        calls += 1
        if shouldFail {
            shouldFail = false
            throw YamiboError.securityVerificationRequired
        }
        return MessageUnreadSummary(privateMessageCount: count, noticeCount: 0)
    }
}

private actor UnreadMessagePages: MessageCenterPageLoading, PrivateMessagePageLoading {
    func fetchPrivateMessages(page: Int) async throws -> UserSpacePrivateMessagePage {
        .init(messages: [], unreadCount: 999, pageNavigation: .init(currentPage: page, totalPages: 2))
    }
    func fetchNotices(page: Int) async throws -> UserSpaceNoticePage { .init(notices: []) }
    func fetchPrivateMessagePage(uid: String, page: Int?, titleHint: String?) async throws -> PrivateMessagePage {
        .init(title: "Test", privateMessageID: "1", toUID: uid, toName: titleHint, formHash: "hash", messages: [])
    }
    func sendPrivateMessage(privateMessageID: String, uid: String, formHash: String, message: String) async throws -> String { "Sent" }
}

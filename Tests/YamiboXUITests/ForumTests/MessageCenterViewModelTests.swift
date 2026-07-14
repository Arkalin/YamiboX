import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class MessageCenterViewModelTests: XCTestCase {
    func testLoadFetchesPrivateMessagesByDefault() async throws {
        let repository = MessageCenterRepositoryStub()
        let model = MessageCenterViewModel(repository: repository)

        await model.load()

        XCTAssertEqual(model.selectedTab, .privateMessages)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.navigationTitle, "我的消息")
        if case let .privateMessages(page) = model.content {
            XCTAssertEqual(page.messages.map(\.uid), ["800001"])
        } else {
            XCTFail("Expected private messages content")
        }
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["privateMessages:1"])
    }

    func testSelectingNoticesLoadsFirstNoticePageAndPaginationLoadsNextPage() async throws {
        let repository = MessageCenterRepositoryStub()
        let model = MessageCenterViewModel(repository: repository)

        await model.selectTab(.notices)
        await model.goToPage(2)

        XCTAssertEqual(model.selectedTab, .notices)
        XCTAssertEqual(model.currentPage, 2)
        XCTAssertEqual(model.navigationTitle, "我的提醒")
        if case let .notices(page) = model.content {
            XCTAssertEqual(page.notices.map(\.noticeID), ["notice-2"])
        } else {
            XCTFail("Expected notices content")
        }
        let calls = await repository.calls()
        XCTAssertEqual(calls, ["notices:1", "notices:2"])
    }

    func testLoadStoresError() async throws {
        let repository = MessageCenterRepositoryStub(error: YamiboError.parsingFailed(context: "messages"))
        let model = MessageCenterViewModel(repository: repository)

        await model.load()

        XCTAssertNil(model.content)
        XCTAssertNotNil(model.errorMessage)
    }

    /// generation-guard coverage: quickly switching tabs must not let a slow
    /// response for the tab that's no longer selected land after the newly
    /// selected tab's faster response and overwrite its content.
    func testStaleTabResponseDoesNotOverwriteNewerTabContent() async throws {
        let repository = MessageCenterRepositoryStub()
        await repository.setGatedPrivateMessagesPages([1])
        let model = MessageCenterViewModel(repository: repository)

        let staleTask = Task { await model.load() }
        await repository.waitUntilPrivateMessagesBlocked()

        await model.selectTab(.notices)
        if case .notices = model.content {
        } else {
            XCTFail("Expected notices content")
        }
        XCTAssertEqual(model.selectedTab, .notices)

        await repository.releasePrivateMessages()
        await staleTask.value

        if case .notices = model.content {
        } else {
            XCTFail("Expected notices content to remain after the stale private-messages response landed")
        }
        XCTAssertEqual(model.selectedTab, .notices)
    }

    /// isLoading generation coverage: a superseded request completing while
    /// the newer request is still in flight must not clear the newer
    /// request's loading indicator.
    func testStaleRequestCompletionDoesNotClearNewerRequestLoadingIndicator() async throws {
        let repository = MessageCenterRepositoryStub()
        await repository.setGatedPrivateMessagesPages([1])
        await repository.setGatedNoticesPages([1])
        let model = MessageCenterViewModel(repository: repository)

        let staleTask = Task { await model.load() }
        await repository.waitUntilPrivateMessagesBlocked()
        XCTAssertTrue(model.isLoading)

        let newerTask = Task { await model.selectTab(.notices) }
        await repository.waitUntilNoticesBlocked()
        XCTAssertTrue(model.isLoading)

        await repository.releasePrivateMessages()
        await staleTask.value
        XCTAssertTrue(model.isLoading)

        await repository.releaseNotices()
        await newerTask.value

        XCTAssertFalse(model.isLoading)
        if case .notices = model.content {
        } else {
            XCTFail("Expected notices content")
        }
    }
}

private actor MessageCenterRepositoryStub: MessageCenterPageLoading {
    let error: Error?
    var recordedCalls: [String] = []
    /// Gate used by the stale-response race test to hold a
    /// `fetchPrivateMessages` call in flight until the newer tab's response
    /// has already landed.
    private var gatedPrivateMessagesPages: Set<Int> = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var isBlocking = false
    private var released = false
    /// Independent gate for `fetchNotices`, so a test can hold two requests
    /// in flight at once and release them in a chosen order.
    private var gatedNoticesPages: Set<Int> = []
    private var noticesContinuation: CheckedContinuation<Void, Never>?
    private var isNoticesBlocking = false
    private var noticesReleased = false

    init(error: Error? = nil) {
        self.error = error
    }

    func fetchPrivateMessages(page: Int) async throws -> UserSpacePrivateMessagePage {
        recordedCalls.append("privateMessages:\(page)")
        if gatedPrivateMessagesPages.contains(page) {
            await waitIfNeeded()
        }
        if let error { throw error }
        return UserSpacePrivateMessagePage(
            messages: [
                UserSpacePrivateMessageSummary(
                    uid: "800001",
                    name: "好友A",
                    title: "好友A",
                    message: "最近一条消息",
                    timeText: "2026-06-01 10:30"
                )
            ],
            pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 3)
        )
    }

    func fetchNotices(page: Int) async throws -> UserSpaceNoticePage {
        recordedCalls.append("notices:\(page)")
        if gatedNoticesPages.contains(page) {
            await waitForNoticesIfNeeded()
        }
        if let error { throw error }
        return UserSpaceNoticePage(
            notices: [
                UserSpaceNoticeSummary(
                    noticeID: "notice-\(page)",
                    contentHTML: "提醒",
                    contentText: "提醒"
                )
            ],
            pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 3)
        )
    }

    func calls() -> [String] {
        recordedCalls
    }

    func setGatedPrivateMessagesPages(_ pages: Set<Int>) {
        gatedPrivateMessagesPages = pages
    }

    private func waitIfNeeded() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isBlocking = true
        }
    }

    func waitUntilPrivateMessagesBlocked() async {
        while !isBlocking {
            await Task.yield()
        }
    }

    func releasePrivateMessages() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func setGatedNoticesPages(_ pages: Set<Int>) {
        gatedNoticesPages = pages
    }

    private func waitForNoticesIfNeeded() async {
        guard !noticesReleased else { return }
        await withCheckedContinuation { continuation in
            noticesContinuation = continuation
            isNoticesBlocking = true
        }
    }

    func waitUntilNoticesBlocked() async {
        while !isNoticesBlocking {
            await Task.yield()
        }
    }

    func releaseNotices() {
        noticesReleased = true
        noticesContinuation?.resume()
        noticesContinuation = nil
    }
}

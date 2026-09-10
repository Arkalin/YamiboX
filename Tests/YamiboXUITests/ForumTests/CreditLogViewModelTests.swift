import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class CreditLogViewModelTests: XCTestCase {
    func testDefaultsToAllAndAvoidsReloadWhenReturningFromALink() async {
        let repository = CreditLogRepositoryStub()
        let model = CreditLogViewModel(repository: repository)
        await model.load()
        await model.load()
        XCTAssertEqual(model.selectedFilter, .all)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.content?.entries.first?.id, "all:1")
        let calls = await repository.calls
        XCTAssertEqual(calls, ["all:1"])
    }

    func testFilterSwitchResetsPageAndRefreshKeepsCurrentPage() async {
        let repository = CreditLogRepositoryStub()
        let model = CreditLogViewModel(repository: repository)
        await model.load()
        await model.goToPage(2)
        await model.refresh()
        await model.selectFilter(.income)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.content?.entries.first?.id, "income:1")
        await model.selectFilter(.expense)
        await model.selectFilter(.expense)
        XCTAssertEqual(model.content?.entries.first?.id, "expense:1")
        let calls = await repository.calls
        XCTAssertEqual(calls, ["all:1", "all:2", "all:2", "income:1", "expense:1"])
    }

    func testPageLimitsDoNotIssueOutOfBoundsRequests() async {
        let repository = CreditLogRepositoryStub()
        let model = CreditLogViewModel(repository: repository)
        await model.load()
        await model.goToPage(-5)
        await model.goToPage(99)
        await model.goToPage(4)
        XCTAssertEqual(model.currentPage, 3)
        let calls = await repository.calls
        XCTAssertEqual(calls, ["all:1", "all:3"])
    }

    func testRefreshFailurePreservesRecordsAndPage() async {
        let repository = CreditLogRepositoryStub()
        let model = CreditLogViewModel(repository: repository)
        await model.load()
        await model.goToPage(2)
        let oldContent = model.content
        await repository.setFailure(.offline, for: "all:2")
        await model.refresh()
        XCTAssertEqual(model.content, oldContent)
        XCTAssertEqual(model.currentPage, 2)
        XCTAssertNotNil(model.errorDetails)
        XCTAssertFalse(model.isLoading)
        await repository.setFailure(nil, for: "all:2")
        await model.retry()
        XCTAssertNil(model.errorDetails)
        XCTAssertEqual(model.currentPage, 2)
    }

    func testPageFailurePreservesOldPageAndRetryLoadsTheFailedTarget() async {
        let repository = CreditLogRepositoryStub()
        let model = CreditLogViewModel(repository: repository)
        await model.load()
        let oldContent = model.content
        let oldScrollIdentity = model.scrollIdentity
        await repository.setFailure(.offline, for: "all:2")
        await model.goToPage(2)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.content, oldContent)
        XCTAssertEqual(model.scrollIdentity, oldScrollIdentity)
        await repository.setFailure(nil, for: "all:2")
        await model.retry()
        XCTAssertEqual(model.currentPage, 2)
        XCTAssertNotEqual(model.scrollIdentity, oldScrollIdentity)
        XCTAssertNil(model.errorDetails)
    }

    func testInitialFailureCanBeRetriedAndFilterSwitchDoesNotKeepTheOldError() async {
        let repository = CreditLogRepositoryStub()
        await repository.setFailure(.offline, for: "all:1")
        let model = CreditLogViewModel(repository: repository)
        await model.load()
        XCTAssertNil(model.content)
        XCTAssertNotNil(model.errorDetails)
        await repository.setFailure(nil, for: "all:1")
        await model.retry()
        XCTAssertNotNil(model.content)
        await model.selectFilter(.expense)
        XCTAssertNil(model.errorDetails)
        XCTAssertEqual(model.currentPage, 1)
    }

    func testSlowOldFilterCannotReplaceNewFilterOrClearItsSpinner() async {
        let repository = CreditLogRepositoryStub()
        await repository.gate("all:1")
        await repository.gate("income:1")
        let model = CreditLogViewModel(repository: repository)
        let old = Task { await model.load() }
        await repository.waitUntilBlocked("all:1")
        let next = Task { await model.selectFilter(.income) }
        await repository.waitUntilBlocked("income:1")
        XCTAssertNil(model.content)
        XCTAssertEqual(model.currentPage, 1)
        await repository.release("all:1")
        await old.value
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.content)
        await repository.release("income:1")
        await next.value
        XCTAssertEqual(model.content?.entries.first?.id, "income:1")
        XCTAssertFalse(model.isLoading)
    }

    func testStaleFailureDoesNotClearSuccessfulNewFilter() async {
        let repository = CreditLogRepositoryStub()
        await repository.setFailure(.offline, for: "all:1")
        await repository.gate("all:1")
        let model = CreditLogViewModel(repository: repository)
        let old = Task { await model.load() }
        await repository.waitUntilBlocked("all:1")
        await model.selectFilter(.expense)
        await repository.release("all:1")
        await old.value
        XCTAssertEqual(model.content?.entries.first?.id, "expense:1")
        XCTAssertNil(model.errorDetails)
    }

    func testCancellationIsSilentAndRetryLoadsAgain() async {
        let repository = CreditLogRepositoryStub()
        await repository.gate("all:1")
        let model = CreditLogViewModel(repository: repository)
        let loading = Task { await model.load() }
        await repository.waitUntilBlocked("all:1")
        loading.cancel()
        await repository.release("all:1")
        await loading.value
        XCTAssertNil(model.errorDetails)
        XCTAssertNil(model.content)
        XCTAssertFalse(model.isLoading)
        await model.load()
        XCTAssertNotNil(model.content)
    }

    func testAccountGenerationChangeDiscardsOldResponse() async throws {
        let store = try makeSessionStore()
        try await store.save(SessionState(cookie: "EeqY_2132_auth=one", isLoggedIn: true, accountUID: "1"))
        let repository = CreditLogRepositoryStub()
        await repository.gate("all:1")
        let oldModel = CreditLogViewModel(repository: repository, sessionStore: store)
        let old = Task { await oldModel.load() }
        await repository.waitUntilBlocked("all:1")
        try await store.save(SessionState(cookie: "EeqY_2132_auth=two", isLoggedIn: true, accountUID: "2"))
        await repository.release("all:1")
        await old.value
        XCTAssertNil(oldModel.content)
        XCTAssertNil(oldModel.errorDetails)
        let newModel = CreditLogViewModel(repository: repository, sessionStore: store)
        await newModel.load()
        XCTAssertEqual(newModel.selectedFilter, .all)
        XCTAssertNotNil(newModel.content)
    }

    func testLoggedOutSessionDoesNotFetchPrivateRecords() async throws {
        let repository = CreditLogRepositoryStub()
        let model = CreditLogViewModel(repository: repository, sessionStore: try makeSessionStore())
        await model.load()
        XCTAssertNil(model.content)
        XCTAssertEqual(model.errorDetails?.summary, YamiboError.notAuthenticated.localizedDescription)
        let calls = await repository.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWrappedLoginFailureClearsPreviouslyDisplayedRecords() async {
        let repository = CreditLogRepositoryStub()
        let model = CreditLogViewModel(repository: repository)
        await model.load()
        await repository.setFailure(.notAuthenticated, for: "all:1")
        await model.refresh()
        XCTAssertNil(model.content)
        XCTAssertEqual(model.errorDetails?.summary, YamiboError.notAuthenticated.localizedDescription)
    }

    func testEmptyPageHasFilterSpecificMessage() async {
        let model = CreditLogViewModel(repository: EmptyCreditLogRepository())
        for filter in CreditLogFilter.allCases {
            if filter == .all { await model.load() } else { await model.selectFilter(filter) }
            XCTAssertEqual(model.content?.entries, [])
            XCTAssertFalse(model.emptyMessage.isEmpty)
            XCTAssertNil(model.errorDetails)
        }
        XCTAssertEqual(model.emptyMessage, "暂无支出记录")
    }

    private func makeSessionStore() throws -> SessionStore {
        let defaults = try YamiboTestDefaults.make(suiteName: YamiboTestDefaults.suiteName(prefix: "credit-log"))
        return SessionStore(defaults: defaults, key: "session")
    }
}

private actor CreditLogRepositoryStub: CreditLogPageLoading {
    private(set) var calls: [String] = []
    private var failures: [String: YamiboError] = [:]
    private var gates: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func setFailure(_ error: YamiboError?, for key: String) { failures[key] = error }
    func gate(_ key: String) { gates.insert(key) }
    func waitUntilBlocked(_ key: String) async {
        while continuations[key] == nil { await Task.yield() }
    }
    func release(_ key: String) {
        gates.remove(key)
        continuations.removeValue(forKey: key)?.resume()
    }

    func fetchCreditLog(filter: CreditLogFilter, page: Int) async throws -> CreditLogPage {
        let key = "\(filter.rawValue):\(page)"
        calls.append(key)
        let failure = failures[key]
        if gates.contains(key) {
            await withCheckedContinuation { continuations[key] = $0 }
        }
        if let failure {
            throw LoadDiagnosticError(underlying: failure, details: LoadFailureDetails(error: failure))
        }
        return CreditLogPage(
            entries: [CreditLogEntry(
                id: key,
                operation: "天天打卡",
                changes: [CreditLogChange(name: "对象", valueText: "+1", amount: 1)],
                description: ForumThreadTextBlock(text: "天天打卡"),
                timeText: "2026-09-10 00:22"
            )],
            pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 3)
        )
    }
}

private struct EmptyCreditLogRepository: CreditLogPageLoading {
    func fetchCreditLog(filter: CreditLogFilter, page: Int) async throws -> CreditLogPage {
        CreditLogPage(entries: [])
    }
}

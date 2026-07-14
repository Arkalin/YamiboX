import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ForumSearchViewModelTests: XCTestCase {
    func testSearchFirstPageUsesFormHashAndForumScope() async throws {
        let firstPage = makeSearchPage(query: "百合", searchID: "99", page: 1, threadIDs: ["100"])
        let repository = ForumSearchRepositoryStub(pages: [firstPage])
        let model = ForumSearchViewModel(forumID: "5", repository: repository, formHash: "f47bb54f")
        model.query = " 百合 "

        await model.searchFirstPage()

        XCTAssertEqual(model.results.map(\.tid), ["100"])
        XCTAssertEqual(model.currentSearchID, "99")
        XCTAssertEqual(model.currentPage, 1)
        let searches = await repository.searchRequests()
        XCTAssertEqual(searches, [.init(query: "百合", forumID: "5", formHash: "f47bb54f")])
    }

    func testGoToPageUsesCurrentSearchIDAndRestoresPreviousPage() async throws {
        let firstPage = makeSearchPage(query: "百合", searchID: "99", page: 1, threadIDs: ["100"])
        let secondPage = makeSearchPage(query: "百合", searchID: "99", page: 2, threadIDs: ["200"])
        let repository = ForumSearchRepositoryStub(pages: [firstPage, secondPage])
        let model = ForumSearchViewModel(forumID: nil, repository: repository, formHash: "f47bb54f")
        model.query = "百合"

        await model.searchFirstPage()
        await model.goToPage(2)

        XCTAssertEqual(model.results.map(\.tid), ["200"])
        XCTAssertEqual(model.currentPage, 2)
        let pageRequests = await repository.pageRequests()
        XCTAssertEqual(pageRequests, [.init(query: "百合", searchID: "99", page: 2)])
        XCTAssertTrue(model.restorePreviousPage())
        XCTAssertEqual(model.results.map(\.tid), ["100"])
        XCTAssertEqual(model.currentPage, 1)
    }

    func testSearchFirstPageShowsMissingTokenError() async throws {
        let repository = ForumSearchRepositoryStub(error: YamiboError.missingForumSearchToken)
        let model = ForumSearchViewModel(forumID: nil, repository: repository, formHash: nil)
        model.query = "百合"

        await model.searchFirstPage()

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.errorMessage, YamiboError.missingForumSearchToken.localizedDescription)
    }

    /// generation-guard coverage: a slow `goToPage(2)` response landing after
    /// a faster, later `goToPage(3)` must be discarded rather than clobbering
    /// the already-displayed page 3 results back to page 2.
    func testStaleGoToPageResponseDoesNotOverwriteNewerPage() async throws {
        let firstPage = makeSearchPage(query: "百合", searchID: "99", page: 1, threadIDs: ["100"])
        let secondPage = makeSearchPage(query: "百合", searchID: "99", page: 2, threadIDs: ["200"])
        let thirdPage = makeSearchPage(query: "百合", searchID: "99", page: 3, threadIDs: ["300"])
        let repository = ForumSearchRepositoryStub(pages: [firstPage])
        await repository.setPagedResult(secondPage, forPage: 2)
        await repository.setPagedResult(thirdPage, forPage: 3)
        await repository.setGatedPages([2])
        let model = ForumSearchViewModel(forumID: nil, repository: repository, formHash: "f47bb54f")
        model.query = "百合"

        await model.searchFirstPage()

        let staleTask = Task { await model.goToPage(2) }
        await repository.waitUntilBlocked()

        await model.goToPage(3)
        XCTAssertEqual(model.currentPage, 3)
        XCTAssertEqual(model.results.map(\.tid), ["300"])

        await repository.release()
        await staleTask.value

        XCTAssertEqual(model.currentPage, 3)
        XCTAssertEqual(model.results.map(\.tid), ["300"])
    }

    /// Restoring a previous page while a pagination request is in flight
    /// turns that request stale (generation bump), so its generation-guarded
    /// defer can no longer clear the spinner — the restore itself must.
    func testRestorePreviousPageWhileRequestInFlightClearsLoadingIndicator() async throws {
        let firstPage = makeSearchPage(query: "百合", searchID: "99", page: 1, threadIDs: ["100"])
        let secondPage = makeSearchPage(query: "百合", searchID: "99", page: 2, threadIDs: ["200"])
        let thirdPage = makeSearchPage(query: "百合", searchID: "99", page: 3, threadIDs: ["300"])
        let repository = ForumSearchRepositoryStub(pages: [firstPage])
        await repository.setPagedResult(secondPage, forPage: 2)
        await repository.setPagedResult(thirdPage, forPage: 3)
        await repository.setGatedPages([3])
        let model = ForumSearchViewModel(forumID: nil, repository: repository, formHash: "f47bb54f")
        model.query = "百合"

        await model.searchFirstPage()
        await model.goToPage(2)

        let staleTask = Task { await model.goToPage(3) }
        await repository.waitUntilBlocked()
        XCTAssertTrue(model.isLoading)

        XCTAssertTrue(model.restorePreviousPage())
        XCTAssertFalse(model.isLoading)

        await repository.release()
        await staleTask.value

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.currentPage, 2)
        XCTAssertEqual(model.results.map(\.tid), ["200"])
    }
}

private actor ForumSearchRepositoryStub: ForumSearchPageLoading {
    struct SearchRequest: Equatable {
        var query: String
        var forumID: String?
        var formHash: String?
    }

    struct PageRequest: Equatable {
        var query: String
        var searchID: String
        var page: Int
    }

    let error: Error?
    var pages: [ForumSearchPage]
    var searches: [SearchRequest] = []
    var searchPages: [PageRequest] = []
    /// Page-keyed overrides used by the stale-response race test, so a
    /// gated call doesn't steal the queue slot meant for a later page.
    private var pagedResults: [Int: ForumSearchPage] = [:]
    private var gatedPages: Set<Int> = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var isBlocking = false
    private var released = false

    init(pages: [ForumSearchPage] = [], error: Error? = nil) {
        self.pages = pages
        self.error = error
    }

    func searchForum(query: String, forumID: String?, formHash: String?) async throws -> ForumSearchPage {
        searches.append(.init(query: query, forumID: forumID, formHash: formHash))
        if let error {
            throw error
        }
        return pages.removeFirst()
    }

    func searchForumPage(query: String, searchID: String, page: Int) async throws -> ForumSearchPage {
        searchPages.append(.init(query: query, searchID: searchID, page: page))
        if gatedPages.contains(page) {
            await waitIfNeeded()
        }
        if let error {
            throw error
        }
        if let pagedResult = pagedResults[page] {
            return pagedResult
        }
        return pages.removeFirst()
    }

    func searchRequests() -> [SearchRequest] {
        searches
    }

    func pageRequests() -> [PageRequest] {
        searchPages
    }

    func setPagedResult(_ result: ForumSearchPage, forPage page: Int) {
        pagedResults[page] = result
    }

    func setGatedPages(_ pages: Set<Int>) {
        gatedPages = pages
    }

    private func waitIfNeeded() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isBlocking = true
        }
    }

    func waitUntilBlocked() async {
        while !isBlocking {
            await Task.yield()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private func makeSearchPage(
    query: String,
    searchID: String,
    page: Int,
    threadIDs: [String]
) -> ForumSearchPage {
    ForumSearchPage(
        query: query,
        searchID: searchID,
        totalCount: threadIDs.count,
        results: threadIDs.map { id in
            ForumThreadSummary(
                tid: id,
                title: "Thread \(id)",
                url: URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=\(id)&mobile=2")!
            )
        },
        pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 3)
    )
}

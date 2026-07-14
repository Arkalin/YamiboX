import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class ForumHomeViewModelTests: XCTestCase {
    func testLoadShowsCachedHomeThenRefreshesWithoutResettingExpansion() async throws {
        let cached = makeHome(categoryIDs: ["a", "b", "c", "d"])
        let refreshed = makeHome(categoryIDs: ["a", "b", "c", "d", "e"])
        let repository = ForumHomeRepositoryStub(cached: cached, fetched: refreshed)
        let model = ForumHomeViewModel(repository: repository)

        await model.load()
        model.toggleCategory(id: "b")
        await model.refresh()

        XCTAssertEqual(model.categories.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertTrue(model.expandedCategoryIDs.contains("a"))
        XCTAssertFalse(model.expandedCategoryIDs.contains("b"))
        XCTAssertTrue(model.expandedCategoryIDs.contains("c"))
        XCTAssertFalse(model.expandedCategoryIDs.contains("d"))
    }

    func testLoadPresentsErrorWhenNoCacheAndFetchFails() async throws {
        let repository = ForumHomeRepositoryStub(cached: nil, error: YamiboError.parsingFailed(context: "fixture"))
        let model = ForumHomeViewModel(repository: repository)

        await model.load()

        XCTAssertNil(model.page)
        XCTAssertNotNil(model.errorMessage)
    }

    func testManualRefreshFailureKeepsCachedHomeAndPresentsTransientMessage() async throws {
        let cached = makeHome(categoryIDs: ["a", "b"])
        let error = YamiboError.parsingFailed(context: "fixture")
        let repository = ForumHomeRepositoryStub(cached: cached, error: error)
        let model = ForumHomeViewModel(repository: repository)

        await model.load()
        await model.refresh()

        XCTAssertEqual(model.categories.map(\.id), ["a", "b"])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.transientMessage, L10n.string("forum.home.refresh_failed", error.localizedDescription))
    }

    func testCachedLoadBackgroundRefreshFailureDoesNotPresentTransientMessage() async throws {
        let cached = makeHome(categoryIDs: ["a", "b"])
        let repository = ForumHomeRepositoryStub(cached: cached, error: YamiboError.parsingFailed(context: "fixture"))
        let model = ForumHomeViewModel(repository: repository)

        await model.load()

        XCTAssertEqual(model.categories.map(\.id), ["a", "b"])
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.transientMessage)
    }

    func testManualRefreshCompletesWhenCallerTaskIsCancelled() async throws {
        let started = DispatchSemaphore(value: 0)
        ForumHomeCancellationTestURLProtocol.configure(
            body: forumHomeCancellationTestHTML(boardName: "取消后完成版"),
            responseDelay: 0.25,
            started: started
        )
        defer { ForumHomeCancellationTestURLProtocol.reset() }

        let repository = ForumRepository(
            client: YamiboClient(session: makeForumHomeCancellationTestSession(), userAgent: "Test-UA"),
            cacheStore: ForumCacheStore(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            )
        )
        let model = ForumHomeViewModel(repository: repository)
        let refreshTask = Task {
            await model.refresh()
        }

        let didStartRefreshRequest = await waitForForumHomeCancellationTestSignal(started)
        XCTAssertTrue(didStartRefreshRequest)
        refreshTask.cancel()
        await refreshTask.value

        XCTAssertEqual(model.categories.first?.boards.first?.name, "取消后完成版")
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.transientMessage)
    }
}

private actor ForumHomeRepositoryStub: ForumHomePageLoading {
    let cached: ForumHomePage?
    let fetched: ForumHomePage?
    let error: Error?

    init(cached: ForumHomePage?, fetched: ForumHomePage? = nil, error: Error? = nil) {
        self.cached = cached
        self.fetched = fetched
        self.error = error
    }

    func cachedForumHome(allowExpired _: Bool) async -> ForumHomePage? {
        cached
    }

    func fetchForumHome(preferCache _: Bool) async throws -> ForumHomePage {
        if let error {
            throw error
        }
        return fetched ?? cached ?? makeHome(categoryIDs: ["fallback"])
    }
}

private func makeHome(categoryIDs: [String]) -> ForumHomePage {
    ForumHomePage(
        categories: categoryIDs.map { id in
            ForumCategory(
                id: id,
                title: "Category \(id)",
                boards: [
                    ForumBoardSummary(
                        fid: id,
                        name: "Board \(id)",
                        url: ForumRouteResolver.boardURL(fid: id)
                    )
                ]
            )
        }
    )
}

private final class ForumHomeCancellationTestURLProtocol: URLProtocol {
    private struct Configuration {
        var body: String
        var responseDelay: TimeInterval
        var started: DispatchSemaphore?
    }

    nonisolated(unsafe) private static var configuration: Configuration?

    static func configure(
        body: String,
        responseDelay: TimeInterval,
        started: DispatchSemaphore? = nil
    ) {
        configuration = Configuration(body: body, responseDelay: responseDelay, started: started)
    }

    static func reset() {
        configuration = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let configuration = Self.configuration else {
            client?.urlProtocol(self, didFailWithError: ForumHomeCancellationTestError.missingConfiguration)
            return
        }

        configuration.started?.signal()
        Thread.sleep(forTimeInterval: configuration.responseDelay)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(configuration.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum ForumHomeCancellationTestError: Error {
    case missingConfiguration
}

private func makeForumHomeCancellationTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForumHomeCancellationTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func forumHomeCancellationTestHTML(boardName: String) -> String {
    #"""
    <html>
    <body id="forum" class="pg_index">
      <div class="forumlist cl">
        <div class="subforumshow cl" href="#sub-forum_14">
          <h2><a href="javascript:;">测试分区</a></h2>
        </div>
        <div id="sub-forum_14" class="sub-forum mlist1 cl">
          <ul>
            <li>
              <a href="forum.php?mod=forumdisplay&amp;fid=16&amp;mobile=2" class="murl">
                <p class="mtit">\#(boardName)</p>
                <p class="mtxt">测试说明</p>
              </a>
            </li>
          </ul>
        </div>
      </div>
    </body>
    </html>
    """#
}

private func waitForForumHomeCancellationTestSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await Task.detached {
        blockingWaitForForumHomeCancellationTestSignal(semaphore)
    }.value
}

private func blockingWaitForForumHomeCancellationTestSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

import Foundation
import XCTest
@testable import YamiboXCore

@MainActor
final class ReaderChapterCommentsModuleTests: XCTestCase {
    func testRepeatedPaginationFailureKeepsCursorAndHasNewFeedbackIdentity() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [.success(makePage(target: target, bodies: ["first"], nextView: 2))],
            moreResults: [.failure(URLError(.timedOut)), .failure(URLError(.timedOut)),
                          .success(makePage(target: target, bodies: ["second"]))]
        )
        let module = makeModule(adapter: adapter)
        await module.load(target)
        await module.loadNextPage()
        let firstID = try XCTUnwrap(module.failureEventID)
        XCTAssertEqual(module.loadMoreErrorDetails?.causes.first?.code, URLError.timedOut.rawValue)
        await module.loadNextPage()
        XCTAssertNotEqual(module.failureEventID, firstID)
        guard case let .loaded(_, page) = module.state else { return XCTFail("Expected retained content") }
        XCTAssertEqual(page.nextView, 2)
        XCTAssertEqual(page.comments.map(\.body), ["first"])
        module.clearTransientFailure()
        XCTAssertNil(module.loadMoreError)
        XCTAssertNil(module.loadMoreErrorDetails)
        XCTAssertNil(module.failureEventID)
        await module.loadNextPage()
        guard case let .loaded(_, result) = module.state else { return XCTFail("Expected retry recovery") }
        XCTAssertEqual(result.comments.map(\.body), ["first", "second"])
        XCTAssertNil(result.nextView)
        let requests = await adapter.moreRequests
        XCTAssertEqual(requests.map(\.view), [2, 2, 2])
    }

    func testRefreshFailureRetainsOriginalErrorWithoutDiscardingCachedComments() async {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(initialResults: [
            .success(makePage(target: target, bodies: ["cached"])), .failure(URLError(.cannotFindHost))
        ])
        let module = makeModule(adapter: adapter)
        await module.load(target)
        await module.refresh(target)
        XCTAssertNotNil(module.failureEventID)
        XCTAssertEqual(module.refreshErrorDetails?.causes.first?.code, URLError.cannotFindHost.rawValue)
        module.clearTransientFailure()
        XCTAssertNil(module.refreshErrorDetails)
        guard case let .loaded(_, page) = module.state else { return XCTFail("Expected retained content") }
        XCTAssertEqual(page.comments.map(\.body), ["cached"])
    }

    func testCancelledPaginationHasNoFailureFeedbackAndKeepsRetryCursor() async {
        let target = makeTarget()
        let module = makeModule(adapter: ChapterCommentsAdapterSpy(
            initialResults: [.success(makePage(target: target, bodies: ["cached"], nextView: 2))],
            moreResults: [.failure(URLError(.cancelled))]
        ))
        await module.load(target)
        await module.loadNextPage()
        XCTAssertNil(module.loadMoreError)
        XCTAssertNil(module.loadMoreErrorDetails)
        XCTAssertNil(module.failureEventID)
        guard case let .loaded(_, page) = module.state else { return XCTFail("Expected retained content") }
        XCTAssertEqual(page.nextView, 2)
    }

    func testRetryReplacesFailureDetailsAndSuccessClearsThem() async {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(initialResults: [
            .failure(URLError(.timedOut)),
            .failure(URLError(.cannotFindHost)),
            .success(makePage(target: target, bodies: ["recovered"]))
        ])
        let module = makeModule(adapter: adapter)
        await module.load(target)
        guard case let .failed(_, _, first) = module.state else { return XCTFail("Expected failure") }
        XCTAssertEqual(first?.causes.first?.code, URLError.timedOut.rawValue)
        await module.load(target)
        guard case let .failed(_, _, second) = module.state else { return XCTFail("Expected failure") }
        XCTAssertEqual(second?.causes.first?.code, URLError.cannotFindHost.rawValue)
        await module.load(target)
        guard case .loaded = module.state else { return XCTFail("Expected recovery") }
    }

    func testCancelledInitialRequestDoesNotCreateFailureDetails() async {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            let module = makeModule(adapter: ChapterCommentsAdapterSpy(initialResults: [.failure(error)]))
            await module.load(makeTarget())
            XCTAssertEqual(module.state, .idle)
        }
    }

    func testLateFailureCannotReplaceAnotherTargetsDetails() async {
        let first = makeTarget()
        var second = first
        second.threadID = "another-thread"
        let gate = ChapterCommentsFailureGate()
        let module = ReaderChapterCommentsModule(adapter: .init(loadInitial: { target in
            if target == first { return try await gate.load() }
            throw URLError(.cannotFindHost)
        }, loadMore: { _, _ in throw URLError(.badURL) }), onChange: nil)
        let oldRequest = Task { await module.load(first) }
        await gate.waitUntilStarted()
        await module.load(second)
        await gate.fail()
        await oldRequest.value
        guard case let .failed(target, _, details) = module.state else { return XCTFail("Expected failure") }
        XCTAssertEqual(target, second)
        XCTAssertEqual(details?.causes.first?.code, URLError.cannotFindHost.rawValue)
    }

    func testLoadUsesCachedPageWithoutCallingAdapterAgain() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [
                .success(makePage(target: target, bodies: ["first"]))
            ]
        )
        let module = makeModule(adapter: adapter)

        await module.load(target)
        await module.load(target)

        guard case let .loaded(_, page) = module.state else {
            XCTFail("Expected cached chapter comments")
            return
        }
        XCTAssertEqual(page.comments.map(\.body), ["first"])
        let initialTargets = await adapter.initialTargets
        XCTAssertEqual(initialTargets, [target])
    }

    func testRefreshSuccessUpdatesCacheAndClearsErrors() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [
                .success(makePage(target: target, bodies: ["old"])),
                .failure(TestError("refresh failed")),
                .success(makePage(target: target, bodies: ["new"]))
            ]
        )
        let module = makeModule(adapter: adapter)

        await module.load(target)
        await module.refresh(target)
        XCTAssertEqual(module.refreshError, "refresh failed")

        await module.refresh(target)
        await module.load(target)

        guard case let .loaded(_, page) = module.state else {
            XCTFail("Expected refreshed chapter comments")
            return
        }
        XCTAssertEqual(page.comments.map(\.body), ["new"])
        XCTAssertNil(module.refreshError)
        let initialTargets = await adapter.initialTargets
        XCTAssertEqual(initialTargets, [target, target, target])
    }

    func testRefreshFirstFailureEntersFailedState() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [.failure(TestError("initial failed"))]
        )
        let module = makeModule(adapter: adapter)

        await module.refresh(target)

        guard case let .failed(failedTarget, message, details) = module.state else {
            return XCTFail("Expected failed state with details")
        }
        XCTAssertEqual(failedTarget, target)
        XCTAssertEqual(message, "initial failed")
        XCTAssertEqual(details?.summary, message)
        XCTAssertNil(module.refreshError)
    }

    func testRefreshFailureWithCachePreservesLoadedPageAndSetsRefreshError() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [
                .success(makePage(target: target, bodies: ["cached"])),
                .failure(TestError("refresh failed"))
            ]
        )
        let module = makeModule(adapter: adapter)

        await module.load(target)
        await module.refresh(target)

        guard case let .loaded(_, page) = module.state else {
            XCTFail("Expected cached comments to remain visible")
            return
        }
        XCTAssertEqual(page.comments.map(\.body), ["cached"])
        XCTAssertEqual(module.refreshError, "refresh failed")
    }

    func testLoadMoreSuccessAppendsPageAndUpdatesCache() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [
                .success(makePage(target: target, bodies: ["first"], nextView: 2))
            ],
            moreResults: [
                .success(makePage(target: target, bodies: ["second"], nextView: nil))
            ]
        )
        let module = makeModule(adapter: adapter)

        await module.load(target)
        await module.loadNextPage()
        await module.load(target)

        guard case let .loaded(_, page) = module.state else {
            XCTFail("Expected merged chapter comments")
            return
        }
        XCTAssertEqual(page.comments.map(\.body), ["first", "second"])
        XCTAssertNil(page.nextView)
        let moreRequests = await adapter.moreRequests
        XCTAssertEqual(moreRequests, [ChapterCommentsAdapterSpy.MoreRequest(target: target, view: 2)])
    }

    func testLoadMoreFailurePreservesCurrentPageAndResetsLoadingFlag() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [
                .success(makePage(target: target, bodies: ["first"], nextView: 2))
            ],
            moreResults: [.failure(TestError("more failed"))]
        )
        let module = makeModule(adapter: adapter)

        await module.load(target)
        await module.loadNextPage()

        guard case let .loaded(_, page) = module.state else {
            XCTFail("Expected current comments to remain visible")
            return
        }
        XCTAssertEqual(page.comments.map(\.body), ["first"])
        XCTAssertFalse(module.isLoadingMore)
        XCTAssertEqual(module.loadMoreError, "more failed")
    }

    func testNilTargetIsUnsupported() async throws {
        let adapter = ChapterCommentsAdapterSpy()
        let module = makeModule(adapter: adapter)

        await module.load(nil)

        XCTAssertEqual(module.state, .unsupported)
        let initialTargets = await adapter.initialTargets
        XCTAssertTrue(initialTargets.isEmpty)
    }

    func testRefreshNilTargetIsUnsupported() async throws {
        let adapter = ChapterCommentsAdapterSpy()
        let module = makeModule(adapter: adapter)

        await module.refresh(nil)

        XCTAssertEqual(module.state, .unsupported)
        let initialTargets = await adapter.initialTargets
        XCTAssertTrue(initialTargets.isEmpty)
    }

    func testCacheIsSeparatedByFullTarget() async throws {
        let target = makeTarget()
        let sameThreadDifferentOwner = makeTarget(ownerPostID: "101")
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [
                .success(makePage(target: target, bodies: ["first-owner"])),
                .success(makePage(target: sameThreadDifferentOwner, bodies: ["second-owner"]))
            ]
        )
        let module = makeModule(adapter: adapter)

        await module.load(target)
        await module.load(sameThreadDifferentOwner)
        await module.load(target)

        guard case let .loaded(loadedTarget, page) = module.state else {
            XCTFail("Expected cached comments for the original full target")
            return
        }
        XCTAssertEqual(loadedTarget, target)
        XCTAssertEqual(page.comments.map(\.body), ["first-owner"])
        let initialTargets = await adapter.initialTargets
        XCTAssertEqual(initialTargets, [target, sameThreadDifferentOwner])
    }

    func testLoadMoreWithoutLoadedStateDoesNotCallAdapter() async throws {
        let adapter = ChapterCommentsAdapterSpy()
        let module = makeModule(adapter: adapter)

        await module.loadNextPage()

        let moreRequests = await adapter.moreRequests
        XCTAssertTrue(moreRequests.isEmpty)
        XCTAssertFalse(module.isLoadingMore)
    }

    func testLoadMoreWithoutNextViewDoesNotCallAdapter() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [
                .success(makePage(target: target, bodies: ["only-page"], nextView: nil))
            ]
        )
        let module = makeModule(adapter: adapter)

        await module.load(target)
        await module.loadNextPage()

        let moreRequests = await adapter.moreRequests
        XCTAssertTrue(moreRequests.isEmpty)
        XCTAssertFalse(module.isLoadingMore)
    }

    func testLoadCachedTargetClearsRefreshErrorAndPreservesLoadMoreError() async throws {
        let target = makeTarget()
        let adapter = ChapterCommentsAdapterSpy(
            initialResults: [
                .success(makePage(target: target, bodies: ["cached"], nextView: 2)),
                .failure(TestError("refresh failed"))
            ],
            moreResults: [.failure(TestError("more failed"))]
        )
        let module = makeModule(adapter: adapter)

        await module.load(target)
        await module.refresh(target)
        await module.loadNextPage()
        await module.load(target)

        guard case let .loaded(_, page) = module.state else {
            XCTFail("Expected cached comments")
            return
        }
        XCTAssertEqual(page.comments.map(\.body), ["cached"])
        XCTAssertNil(module.refreshError)
        XCTAssertEqual(module.loadMoreError, "more failed")
    }
}

private actor ChapterCommentsFailureGate {
    private var pending: CheckedContinuation<ChapterCommentsPage, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func load() async throws -> ChapterCommentsPage {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func fail() {
        pending?.resume(throwing: URLError(.timedOut))
        pending = nil
    }
}

private actor ChapterCommentsAdapterSpy {
    struct MoreRequest: Equatable {
        var target: ReaderChapterCommentTarget
        var view: Int
    }

    private var initialResults: [Result<ChapterCommentsPage, Error>]
    private var moreResults: [Result<ChapterCommentsPage, Error>]
    private(set) var initialTargets: [ReaderChapterCommentTarget] = []
    private(set) var moreRequests: [MoreRequest] = []

    init(
        initialResults: [Result<ChapterCommentsPage, Error>] = [],
        moreResults: [Result<ChapterCommentsPage, Error>] = []
    ) {
        self.initialResults = initialResults
        self.moreResults = moreResults
    }

    func takeInitial(for target: ReaderChapterCommentTarget) throws -> ChapterCommentsPage {
        initialTargets.append(target)
        return try initialResults.removeFirst().get()
    }

    func takeMore(target: ReaderChapterCommentTarget, view: Int) throws -> ChapterCommentsPage {
        moreRequests.append(MoreRequest(target: target, view: view))
        return try moreResults.removeFirst().get()
    }
}

private func makeModule(adapter: ChapterCommentsAdapterSpy) -> ReaderChapterCommentsModule {
    ReaderChapterCommentsModule(
        adapter: ReaderChapterCommentsModule.Adapter(
            loadInitial: { target in
                try await adapter.takeInitial(for: target)
            },
            loadMore: { target, view in
                try await adapter.takeMore(target: target, view: view)
            }
        ),
        onChange: nil
    )
}

private struct TestError: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private func makeTarget(
    ownerPostID: String = "100",
    title: String? = "第一章",
    authorID: String? = nil
) -> ReaderChapterCommentTarget {
    ReaderChapterCommentTarget(
        threadID: "9001",
        view: 1,
        ownerPostID: ownerPostID,
        title: title,
        authorID: authorID
    )
}

private func makePage(
    target: ReaderChapterCommentTarget,
    bodies: [String],
    nextView: Int? = nil
) -> ChapterCommentsPage {
    ChapterCommentsPage(
        target: target,
        comments: bodies.enumerated().map { index, body in
            ChapterComment(
                id: "\(target.ownerPostID)-\(index)-\(body)",
                source: .postComment,
                authorName: "作者",
                body: body,
                postID: "\(index)"
            )
        },
        isBoundaryClosed: nextView == nil,
        nextView: nextView
    )
}

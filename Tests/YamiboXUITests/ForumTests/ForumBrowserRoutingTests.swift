import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor @Suite
struct ForumBrowserRoutingTests {
    @Test(arguments: BrowserThreadRequest.allCases, BrowserInterveningNavigation.allCases)
    func delayedListOpenDoesNotReplaceNewerDetailNavigation(
        request: BrowserThreadRequest,
        intervening: BrowserInterveningNavigation
    ) async throws {
        let gate = BrowserResolverGate()
        let navigator = try makeBrowserRoutingNavigator(gate: gate)
        let board = ForumDestination.board(fid: "5", title: "Board A", page: nil)
        navigator.path = [board]
        let opening = try openThread(request, navigator: navigator, fromBrowserList: true)
        try await waitForResolver(gate)

        let destination = intervening.destination
        navigator.push(destination)
        let preservedPath = navigator.path
        await gate.release()
        await opening.value

        #expect(navigator.path == preservedPath)
        #expect(navigator.path == [board, destination])
        #expect(navigator.actionErrorMessage == nil)
    }

    @Test(arguments: BrowserThreadRequest.allCases)
    func listOpenStillReplacesTheOldDetailWhenNavigationHasNotChanged(
        request: BrowserThreadRequest
    ) async throws {
        let gate = BrowserResolverGate()
        let navigator = try makeBrowserRoutingNavigator(gate: gate)
        let board = ForumDestination.board(fid: "5", title: "Board A", page: nil)
        navigator.path = [board, oldThread]
        let opening = try openThread(request, navigator: navigator, fromBrowserList: true)
        try await waitForResolver(gate)
        await gate.release()
        await opening.value

        #expect(navigator.browserListPath == [board])
        #expect(navigator.browserDetailPath.count == 1)
        #expect(navigator.selectedBrowserThreadID == "999")
        #expect(!navigator.path.contains(oldThread))
    }

    @Test(arguments: BrowserThreadRequest.allCases, BrowserDetailList.allCases)
    func threadOpenedInsideADetailListKeepsTheDetailHistory(
        request: BrowserThreadRequest,
        detailList: BrowserDetailList
    ) async throws {
        let navigator = try makeBrowserRoutingNavigator()
        let board = ForumDestination.board(fid: "5", title: "Board A", page: nil)
        let originalPath = [board, oldThread, detailList.destination]
        navigator.path = originalPath

        let opening = try openThread(request, navigator: navigator, fromBrowserList: false)
        await opening.value

        #expect(Array(navigator.path.dropLast()) == originalPath)
        #expect(navigator.browserListPath == [board])
        #expect(navigator.browserDetailPath.count == 3)
        guard case let .threadReader(context) = navigator.path.last else {
            Issue.record("Expected the selected thread above its detail-column list")
            return
        }
        #expect(context.thread.tid == "999")
        #expect(navigator.selectedBrowserThreadID == "999")
        navigator.path.removeLast()
        #expect(navigator.path == originalPath)
        #expect(navigator.selectedBrowserThreadID == "123")
    }

    @Test func highlightFollowsNestedThreadsAndBackNavigation() throws {
        let navigator = try makeBrowserRoutingNavigator()
        let board = ForumDestination.board(fid: "5", title: "Board A", page: nil)
        let nextThread = ForumDestination.threadReader(.init(thread: .init(tid: "456"), title: "Linked thread"))
        navigator.path = [board, oldThread]
        #expect(navigator.selectedBrowserThreadID == "123")

        navigator.push(nextThread)
        #expect(navigator.selectedBrowserThreadID == "456")
        navigator.push(.userSpace(uid: "42", name: nil, section: .space, subPage: .profile))
        #expect(navigator.selectedBrowserThreadID == "456")
        navigator.path.removeLast()
        #expect(navigator.selectedBrowserThreadID == "456")
        navigator.path.removeLast()
        #expect(navigator.selectedBrowserThreadID == "123")
        navigator.push(.novelDetail(.init(thread: .init(tid: "789"), title: "Novel")))
        #expect(navigator.selectedBrowserThreadID == "789")
        navigator.push(.mangaDetail(.init(thread: .init(tid: "987"), title: "Manga")))
        #expect(navigator.selectedBrowserThreadID == "987")
        navigator.path.removeLast()
        #expect(navigator.selectedBrowserThreadID == "789")
        navigator.path = navigator.browserListPath
        #expect(navigator.selectedBrowserThreadID == nil)
    }

    @Test func boardAndSearchOpenedWithinDetailDoNotResetThePrimaryList() throws {
        let navigator = try makeBrowserRoutingNavigator()
        let primaryBoard = ForumDestination.board(fid: "5", title: "Board A", page: nil)
        navigator.path = [primaryBoard, oldThread]
        let detailBoard = ForumBoardSummary(
            fid: "6",
            name: "Board B",
            url: YamiboRoute.forumBoard(fid: "6", page: 1, filterID: nil, orderFilter: nil, orderBy: nil).url
        )

        navigator.openBoard(detailBoard)
        navigator.openSearch(fid: detailBoard.fid)

        #expect(navigator.path == [
            primaryBoard, oldThread,
            .board(fid: "6", title: "Board B", page: nil),
            .search(fid: "6")
        ])
        #expect(navigator.browserListPath == [primaryBoard])
    }

    private var oldThread: ForumDestination {
        .threadReader(.init(thread: .init(tid: "123", fid: "5"), title: "Original thread"))
    }

    private func openThread(
        _ request: BrowserThreadRequest,
        navigator: ForumDestinationNavigator,
        fromBrowserList: Bool
    ) throws -> Task<Void, Never> {
        let url = YamiboRoute.threadByID(tid: "999", page: 1, authorID: nil, reverse: false).url
        let task: Task<Void, Never>?
        switch request {
        case .url:
            task = navigator.openThread(
                url,
                title: "New thread",
                containingFid: "6",
                intent: .nativeThreadReader,
                fromBrowserList: fromBrowserList
            )
        case .summary:
            task = navigator.openThread(
                ForumThreadSummary(tid: "999", title: "New thread", url: url, fid: "6"),
                containingFid: "6",
                readerOverride: .plainThread,
                fromBrowserList: fromBrowserList
            )
        }
        return try #require(task)
    }

    private func waitForResolver(_ gate: BrowserResolverGate) async throws {
        do {
            try await waitForCondition(timeout: .seconds(2)) { await gate.isWaiting }
        } catch {
            await gate.release()
            throw error
        }
    }
}

enum BrowserThreadRequest: CaseIterable, Sendable {
    case url
    case summary
}

enum BrowserInterveningNavigation: CaseIterable, Sendable {
    case postEditor
    case userSpace

    var destination: ForumDestination {
        switch self {
        case .postEditor:
            .postEditor(YamiboRoute.threadReply(tid: "123", page: 1).url)
        case .userSpace:
            .userSpace(uid: "42", name: "Author", section: .space, subPage: .profile)
        }
    }
}

enum BrowserDetailList: CaseIterable, Sendable {
    case board
    case search

    var destination: ForumDestination {
        switch self {
        case .board: .board(fid: "6", title: "Board B", page: nil)
        case .search: .search(fid: "6")
        }
    }
}

/// Pauses the injected factory before a real resolver returns a native-thread
/// target. This exercises the navigator's async boundary without networking.
private actor BrowserResolverGate {
    private(set) var isWaiting = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeBrowserRoutingNavigator(gate: BrowserResolverGate? = nil) throws -> ForumDestinationNavigator {
    let fixture = try makeSystemSettingsFixture()
    let source = fixture.appContext.forumDependencies
    let dependencies = ForumDependencies(
        sessionStore: source.sessionStore,
        profileStore: source.profileStore,
        localFavoriteLibraryStore: source.localFavoriteLibraryStore,
        readingProgressStore: source.readingProgressStore,
        settingsStore: source.settingsStore,
        contentCoverStore: source.contentCoverStore,
        mangaDirectoryStore: source.mangaDirectoryStore,
        novelDetailDependencies: source.novelDetailDependencies,
        mangaDetailDependencies: source.mangaDetailDependencies,
        makeForumRepository: source.makeForumRepository,
        makeForumThreadReaderRepository: source.makeForumThreadReaderRepository,
        makeUserSpaceRepository: source.makeUserSpaceRepository,
        makeBlogReaderRepository: source.makeBlogReaderRepository,
        makeFavoriteRepository: source.makeFavoriteRepository,
        makeThreadRouteResolver: {
            await gate?.wait()
            return await source.makeThreadRouteResolver()
        }
    )
    return ForumDestinationNavigator(
        dependencies: dependencies,
        appModel: YamiboAppModel(appContext: fixture.appContext),
        mode: .forumTab,
        usesSplitNavigation: true
    )
}

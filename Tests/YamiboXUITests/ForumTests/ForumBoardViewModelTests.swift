import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class ForumBoardViewModelTests: XCTestCase {
    func testLoadShowsCachedBoardWithoutRefreshing() async throws {
        let cached = makeBoardPage(fid: "5", title: "Cached", page: 1, threadIDs: ["cached"])
        let fetched = makeBoardPage(fid: "5", title: "Fetched", page: 1, threadIDs: ["fresh"])
        let repository = ForumBoardRepositoryStub(cached: cached, fetched: fetched)
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)

        await model.load()

        XCTAssertEqual(model.title, "Cached")
        XCTAssertEqual(model.threads.map(\.tid), ["cached"])
        let requests = await repository.requests()
        XCTAssertEqual(requests.count, 0)
    }

    func testSelectingFilterReloadsFirstPageWithFilterID() async throws {
        let fetched = makeBoardPage(
            fid: "5",
            title: "動漫區",
            page: 2,
            filters: [ForumFilterOption(id: "400", title: "动画讨论")],
            threadIDs: ["before"]
        )
        let filtered = makeBoardPage(
            fid: "5",
            title: "動漫區",
            page: 1,
            filters: [ForumFilterOption(id: "400", title: "动画讨论")],
            threadIDs: ["after"]
        )
        let repository = ForumBoardRepositoryStub(cached: nil, fetchedPages: [fetched, filtered])
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", initialPage: 2, repository: repository)

        await model.load()
        await model.selectFilter(id: "400")

        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.selectedFilterID, "400")
        XCTAssertEqual(model.threads.map(\.tid), ["after"])
        let requests = await repository.requests()
        XCTAssertEqual(requests.map(\.page), [2, 1])
        XCTAssertEqual(requests.last?.filterID, "400")
    }

    func testSelectingOrderReloadsWithOrderFilterAndOrderBy() async throws {
        let fetched = makeBoardPage(
            fid: "5",
            title: "動漫區",
            page: 1,
            orders: [ForumOrderOption(id: "lastpost", title: "最新", filter: "lastpost", orderBy: "lastpost")],
            threadIDs: ["before"]
        )
        let ordered = makeBoardPage(
            fid: "5",
            title: "動漫區",
            page: 1,
            orders: [ForumOrderOption(id: "lastpost", title: "最新", filter: "lastpost", orderBy: "lastpost")],
            threadIDs: ["after"]
        )
        let repository = ForumBoardRepositoryStub(cached: nil, fetchedPages: [fetched, ordered])
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)

        await model.load()
        await model.selectOrder(id: "lastpost")

        XCTAssertEqual(model.selectedOrderOptionID, "lastpost")
        XCTAssertEqual(model.threads.map(\.tid), ["after"])
        let requests = await repository.requests()
        XCTAssertEqual(requests.last?.orderFilter, "lastpost")
        XCTAssertEqual(requests.last?.orderBy, "lastpost")
    }

    func testPagingCanRestorePreviousBoardSnapshot() async throws {
        let first = makeBoardPage(fid: "5", title: "動漫區", page: 1, threadIDs: ["first"])
        let second = makeBoardPage(fid: "5", title: "動漫區", page: 2, threadIDs: ["second"])
        let repository = ForumBoardRepositoryStub(cached: nil, fetchedPages: [first, second])
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)

        await model.load()
        await model.goToPage(2)

        XCTAssertTrue(model.canRestorePreviousPage)
        XCTAssertEqual(model.currentPage, 2)
        XCTAssertEqual(model.threads.map(\.tid), ["second"])

        XCTAssertTrue(model.restorePreviousPage())

        XCTAssertFalse(model.canRestorePreviousPage)
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.threads.map(\.tid), ["first"])
        let requests = await repository.requests()
        XCTAssertEqual(requests.map(\.page), [1, 2])
    }

    func testSelectingFilterClearsBoardPageHistory() async throws {
        let first = makeBoardPage(
            fid: "5",
            title: "動漫區",
            page: 1,
            filters: [ForumFilterOption(id: "400", title: "动画讨论")],
            threadIDs: ["first"]
        )
        let second = makeBoardPage(
            fid: "5",
            title: "動漫區",
            page: 2,
            filters: [ForumFilterOption(id: "400", title: "动画讨论")],
            threadIDs: ["second"]
        )
        let filtered = makeBoardPage(
            fid: "5",
            title: "動漫區",
            page: 1,
            filters: [ForumFilterOption(id: "400", title: "动画讨论")],
            threadIDs: ["filtered"]
        )
        let repository = ForumBoardRepositoryStub(cached: nil, fetchedPages: [first, second, filtered])
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)

        await model.load()
        await model.goToPage(2)
        await model.selectFilter(id: "400")

        XCTAssertFalse(model.canRestorePreviousPage)
        XCTAssertFalse(model.restorePreviousPage())
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.selectedFilterID, "400")
        XCTAssertEqual(model.threads.map(\.tid), ["filtered"])
    }

    func testAddFavoriteUsesCurrentPageFormHash() async throws {
        let fetched = makeBoardPage(fid: "5", title: "動漫區", page: 1, formHash: "f47bb54f", threadIDs: ["fresh"])
        let repository = ForumBoardRepositoryStub(cached: nil, fetched: fetched, favoriteMessage: "收藏成功")
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)

        await model.load()
        await model.addFavorite()

        XCTAssertEqual(model.transientMessage, "收藏成功")
        XCTAssertNil(model.favoriteMessage)
        let favorites = await repository.favoriteRequests()
        XCTAssertEqual(favorites, [.init(fid: "5", formHash: "f47bb54f")])
    }

    func testLoadPresentsErrorWhenNoCacheAndFetchFails() async throws {
        let repository = ForumBoardRepositoryStub(cached: nil, error: YamiboError.parsingFailed(context: "fixture"))
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)

        await model.load()

        XCTAssertNil(model.page)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRefreshFailureKeepsCurrentPageAndPresentsTransientMessage() async throws {
        let fetched = makeBoardPage(fid: "5", title: "動漫區", page: 1, threadIDs: ["fresh"])
        let repository = ForumBoardRepositoryStub(cached: nil, fetched: fetched)
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)
        let error = YamiboError.parsingFailed(context: "fixture")

        await model.load()
        await repository.setError(error)
        await model.refresh()

        XCTAssertNotNil(model.page)
        XCTAssertEqual(model.threads.map(\.tid), ["fresh"])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.transientMessage, L10n.string("forum.board.refresh_failed", error.localizedDescription))
    }

    // MARK: - Board reader settings (pluggable-reader-config Phase C)

    /// Visiting a configured board whose loaded page name differs from the
    /// stored snapshot silently refreshes the snapshot — exactly one settings
    /// write, mode untouched (PRD decision #2).
    func testLoadRefreshesBoardNameSnapshotForConfiguredBoardWhenNameChanged() async throws {
        let settingsStore = try makeBoardSettingsStore(prefix: "forum-board-name-snapshot-refresh")
        var settings = await settingsStore.load()
        settings.boardReader.setEntry(
            .init(mode: .manga(smartEnabled: false), boardName: "旧板块名"),
            forumID: "5"
        )
        try await settingsStore.save(settings)

        let fetched = makeBoardPage(fid: "5", title: "動漫區", page: 1, threadIDs: ["fresh"])
        let repository = ForumBoardRepositoryStub(cached: nil, fetched: fetched)
        let model = ForumBoardViewModel(fid: "5", title: nil, repository: repository, settingsStore: settingsStore)
        let saveCounter = SettingsStoreSaveCounter(changeID: settingsStore.changeID)

        await model.load()

        try await waitForBoardCondition {
            await settingsStore.load().boardReader.entry(forumID: "5")?.boardName == "動漫區"
        }
        let entry = await settingsStore.load().boardReader.entry(forumID: "5")
        XCTAssertEqual(entry, BoardReaderSettings.Entry(mode: .manga(smartEnabled: false), boardName: "動漫區"))
        // Exactly one write for the snapshot refresh. Settle briefly first so
        // a buggy second in-flight write would land and be counted rather
        // than racing this assertion.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(saveCounter.count, 1)
    }

    /// Diff guard: when the stored snapshot already matches the loaded page
    /// name, a routine visit performs no settings write at all.
    func testLoadSkipsSnapshotWriteWhenStoredNameAlreadyMatches() async throws {
        let settingsStore = try makeBoardSettingsStore(prefix: "forum-board-name-snapshot-unchanged")
        var settings = await settingsStore.load()
        settings.boardReader.setEntry(.init(mode: .novel, boardName: "動漫區"), forumID: "5")
        try await settingsStore.save(settings)

        let fetched = makeBoardPage(fid: "5", title: "動漫區", page: 1, threadIDs: ["fresh"])
        let repository = ForumBoardRepositoryStub(cached: nil, fetched: fetched)
        let model = ForumBoardViewModel(fid: "5", title: nil, repository: repository, settingsStore: settingsStore)
        let saveCounter = SettingsStoreSaveCounter(changeID: settingsStore.changeID)

        await model.load()
        // The refresh runs on an unstructured Task; give a would-be write
        // ample time to land before asserting none did.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(saveCounter.count, 0)
        let entry = await settingsStore.load().boardReader.entry(forumID: "5")
        XCTAssertEqual(entry, BoardReaderSettings.Entry(mode: .novel, boardName: "動漫區"))
    }

    /// The snapshot refresh only ever refreshes — visiting an unconfigured
    /// board never creates an entry (and never writes settings).
    func testLoadDoesNotCreateEntryOrWriteSettingsForUnconfiguredBoard() async throws {
        let settingsStore = try makeBoardSettingsStore(prefix: "forum-board-name-snapshot-unconfigured")

        let fetched = makeBoardPage(fid: "5", title: "動漫區", page: 1, threadIDs: ["fresh"])
        let repository = ForumBoardRepositoryStub(cached: nil, fetched: fetched)
        let model = ForumBoardViewModel(fid: "5", title: nil, repository: repository, settingsStore: settingsStore)
        let saveCounter = SettingsStoreSaveCounter(changeID: settingsStore.changeID)

        await model.load()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(saveCounter.count, 0)
        let loaded = await settingsStore.load()
        XCTAssertNil(loaded.boardReader.entry(forumID: "5"))
    }

    /// The reader-settings sheet's "普通" selection maps to
    /// `setBoardReaderMode(.normal)`: the entry is overwritten with an
    /// explicit `.normal` mode — NOT removed (pluggable-reader-config R12) —
    /// keeping the stored board-name snapshot, so the favorites open
    /// dispatch can distinguish "switched back to 普通" from
    /// "never configured".
    func testSetBoardReaderModeNormalPersistsExplicitEntry() async throws {
        let settingsStore = try makeBoardSettingsStore(prefix: "forum-board-reader-mode-plain")
        var settings = await settingsStore.load()
        settings.boardReader.setEntry(.init(mode: .novel, boardName: "動漫區"), forumID: "5")
        try await settingsStore.save(settings)

        let repository = ForumBoardRepositoryStub(cached: nil)
        let model = ForumBoardViewModel(fid: "5", title: nil, repository: repository, settingsStore: settingsStore)
        await model.refreshBoardReaderEntry()
        XCTAssertEqual(model.boardReaderEntry, BoardReaderSettings.Entry(mode: .novel, boardName: "動漫區"))

        model.setBoardReaderMode(.normal)

        let expected = BoardReaderSettings.Entry(mode: .normal, boardName: "動漫區")
        XCTAssertEqual(model.boardReaderEntry, expected)
        try await waitForBoardCondition {
            await settingsStore.load().boardReader.entry(forumID: "5") == expected
        }
        XCTAssertNil(model.boardReaderErrorMessage)
    }

    /// Persistence path for the sheet's "漫画" selection: saving
    /// `.manga(smartEnabled: false)` on a previously-unconfigured board
    /// creates the entry and stamps the loaded page's board name snapshot.
    /// Note: the smart-off-by-default choice itself (PRD decision #8) lives in
    /// `ForumBoardReaderSettingsSheet.modeBinding`, a private SwiftUI binding
    /// this unit test cannot reach — only the resulting save is covered here.
    func testSetBoardReaderModeMangaPersistsSmartOffEntryWithLoadedBoardNameSnapshot() async throws {
        let settingsStore = try makeBoardSettingsStore(prefix: "forum-board-reader-mode-manga")

        let fetched = makeBoardPage(fid: "5", title: "動漫區", page: 1, threadIDs: ["fresh"])
        let repository = ForumBoardRepositoryStub(cached: nil, fetched: fetched)
        let model = ForumBoardViewModel(fid: "5", title: nil, repository: repository, settingsStore: settingsStore)
        await model.load()
        await model.refreshBoardReaderEntry()
        XCTAssertNil(model.boardReaderEntry)

        model.setBoardReaderMode(.manga(smartEnabled: false))

        let expected = BoardReaderSettings.Entry(mode: .manga(smartEnabled: false), boardName: "動漫區")
        XCTAssertEqual(model.boardReaderEntry, expected)
        try await waitForBoardCondition {
            await settingsStore.load().boardReader.entry(forumID: "5") == expected
        }
        XCTAssertNil(model.boardReaderErrorMessage)
    }

    private func makeBoardSettingsStore(prefix: String) throws -> SettingsStore {
        let suiteName = YamiboTestDefaults.suiteName(prefix: prefix)
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        return SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
    }

    /// Reentry/generation interplay: a second `refresh()` while one is
    /// already in flight must be a no-op — it may not advance the generation
    /// and turn the in-flight refresh stale, which would both discard that
    /// refresh's response and (with the generation-guarded defer) leave
    /// `isRefreshing` stuck true forever.
    func testReentrantRefreshDoesNotInvalidateInFlightRefresh() async throws {
        let cached = makeBoardPage(fid: "5", title: "Cached", page: 1, threadIDs: ["cached"])
        let fetched = makeBoardPage(fid: "5", title: "Fetched", page: 1, threadIDs: ["fresh"])
        let repository = ForumBoardRepositoryStub(cached: cached, fetched: fetched)
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)
        await model.load()
        XCTAssertEqual(model.title, "Cached")

        await repository.setGatedPages([1])
        let refreshTask = Task { await model.refresh() }
        await repository.waitUntilBlocked()
        XCTAssertTrue(model.isRefreshing)

        await model.refresh()
        XCTAssertTrue(model.isRefreshing)

        await repository.release()
        await refreshTask.value

        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.title, "Fetched")
        XCTAssertEqual(model.threads.map(\.tid), ["fresh"])
    }

    func testPagingFailureClearsCurrentPageAndCanRestorePreviousSnapshot() async throws {
        let first = makeBoardPage(fid: "5", title: "動漫區", page: 1, threadIDs: ["first"])
        let repository = ForumBoardRepositoryStub(cached: nil, fetched: first)
        let model = ForumBoardViewModel(fid: "5", title: "動漫區", repository: repository)

        await model.load()
        await repository.setError(YamiboError.parsingFailed(context: "fixture"))
        await model.goToPage(2)

        XCTAssertNil(model.page)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.canRestorePreviousPage)

        XCTAssertTrue(model.restorePreviousPage())
        XCTAssertEqual(model.currentPage, 1)
        XCTAssertEqual(model.threads.map(\.tid), ["first"])
        XCTAssertNil(model.errorMessage)
    }
}

/// Counts `SettingsStore.didChangeNotification` posts from ONE specific
/// store (matched by its `changeID`) — the observable signal that a save
/// actually hit the store, used to prove the board-name snapshot refresh's
/// diff guard writes exactly once / not at all.
private final class SettingsStoreSaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var observedCount = 0
    private var token: (any NSObjectProtocol)?

    init(changeID: String) {
        token = NotificationCenter.default.addObserver(
            forName: SettingsStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  notification.userInfo?[SettingsStore.changeIDUserInfoKey] as? String == changeID else {
                return
            }
            self.lock.lock()
            self.observedCount += 1
            self.lock.unlock()
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observedCount
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// Polls an async condition until it's true or the timeout elapses — for
/// asserting on persisted settings that only update from the view model's
/// unstructured save `Task`s, where a fixed sleep would be a flaky guess.
@MainActor
private func waitForBoardCondition(
    timeout: TimeInterval = 2,
    condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for condition")
}

private actor ForumBoardRepositoryStub: ForumBoardPageLoading {
    struct FetchRequest: Equatable {
        var page: Int
        var filterID: String?
        var orderFilter: String?
        var orderBy: String?
        var preferCache: Bool
    }

    struct FavoriteRequest: Equatable {
        var fid: String
        var formHash: String?
    }

    let cached: ForumBoardPage?
    var error: Error?
    let favoriteMessage: String
    var fetchedPages: [ForumBoardPage]
    var fetchRequests: [FetchRequest] = []
    var boardFavoriteRequests: [FavoriteRequest] = []
    /// Gate holding a `fetchForumBoard` call for the listed pages in flight
    /// until `release()`, for deterministic in-flight-request tests.
    private var gatedPages: Set<Int> = []
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var isBlocking = false
    private var released = false

    init(
        cached: ForumBoardPage?,
        fetched: ForumBoardPage? = nil,
        fetchedPages: [ForumBoardPage] = [],
        favoriteMessage: String = "收藏成功",
        error: Error? = nil
    ) {
        self.cached = cached
        self.error = error
        self.favoriteMessage = favoriteMessage
        if let fetched {
            self.fetchedPages = [fetched]
        } else {
            self.fetchedPages = fetchedPages
        }
    }

    func cachedForumBoard(
        fid _: String,
        page _: Int,
        filterID _: String?,
        orderFilter _: String?,
        orderBy _: String?,
        allowExpired _: Bool
    ) async -> ForumBoardPage? {
        cached
    }

    func fetchForumBoard(
        fid _: String,
        title _: String?,
        page: Int,
        filterID: String?,
        orderFilter: String?,
        orderBy: String?,
        preferCache: Bool
    ) async throws -> ForumBoardPage {
        fetchRequests.append(
            FetchRequest(page: page, filterID: filterID, orderFilter: orderFilter, orderBy: orderBy, preferCache: preferCache)
        )
        if gatedPages.contains(page) {
            await waitIfNeeded()
        }
        if let error {
            throw error
        }
        if !fetchedPages.isEmpty {
            return fetchedPages.removeFirst()
        }
        return makeBoardPage(fid: "5", title: "Fallback", page: page, threadIDs: ["fallback"])
    }

    func addBoardFavorite(fid: String, formHash: String?) async throws -> String {
        boardFavoriteRequests.append(.init(fid: fid, formHash: formHash))
        if let error {
            throw error
        }
        return favoriteMessage
    }

    func requests() -> [FetchRequest] {
        fetchRequests
    }

    func setError(_ error: Error?) {
        self.error = error
    }

    func favoriteRequests() -> [FavoriteRequest] {
        boardFavoriteRequests
    }

    func setGatedPages(_ pages: Set<Int>) {
        gatedPages = pages
    }

    private func waitIfNeeded() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            gateContinuation = continuation
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
        gateContinuation?.resume()
        gateContinuation = nil
    }
}

private func makeBoardPage(
    fid: String,
    title: String,
    page: Int,
    formHash: String? = nil,
    filters: [ForumFilterOption] = [],
    orders: [ForumOrderOption] = [],
    threadIDs: [String]
) -> ForumBoardPage {
    ForumBoardPage(
        board: ForumBoardSummary(
            fid: fid,
            name: title,
            url: ForumRouteResolver.boardURL(fid: fid)
        ),
        threads: threadIDs.map { id in
            ForumThreadSummary(
                tid: id,
                title: "Thread \(id)",
                url: URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=\(id)&mobile=2")!
            )
        },
        pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 3),
        filters: filters,
        orders: orders,
        formHash: formHash
    )
}

import XCTest
@testable import YamiboXCore
import YamiboXTestSupport

@MainActor
final class FavoriteUpdateCheckEngineTests: XCTestCase {
    func testUpdateCheckBuildsBaselineDetectsEventsAndHonorsFidFilter() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-updates")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let favoriteUpdateStore = FavoriteUpdateStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "favorite-updates"
        )
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "960")
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "更新检测")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "更新主题",
            sourceGroup: .forumBoard(id: "50", label: "测试板块"),
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        var pagesByThreadID = [
            "960": [
                try makeThreadPage(threadID: "960", postID: "p1", title: "更新主题", replyCount: 1, pageCount: 1),
                try makeThreadPage(threadID: "960", postID: "p2", title: "更新主题", replyCount: 3, pageCount: 2),
                try makeThreadPage(threadID: "960", postID: "p3", title: "更新主题", replyCount: 4, pageCount: 2)
            ]
        ]
        var fetchedThreadIDs: [String] = []
        let engine = try makeUpdateCheckEngine(
            updateStore: favoriteUpdateStore,
            libraryStore: localFavoriteLibraryStore,
            pageFetcher: { item in
                let threadID = try XCTUnwrap(item.target.threadID)
                fetchedThreadIDs.append(threadID)
                var pages = pagesByThreadID[threadID] ?? []
                let page = try XCTUnwrap(pages.first)
                if pages.count > 1 {
                    pages.removeFirst()
                    pagesByThreadID[threadID] = pages
                }
                return page
            }
        )
        await engine.load()

        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)
        XCTAssertEqual(engine.events.count, 0)
        XCTAssertEqual(engine.fidFilters.map(\.fid), ["50"])
        XCTAssertEqual(engine.categoryFilters.map(\.categoryID), [category.id])

        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)
        XCTAssertEqual(engine.events.count, 1)
        XCTAssertEqual(engine.events.first?.title, "更新主题")
        XCTAssertEqual(engine.events.first?.fid, "50")
        XCTAssertEqual(engine.events.first?.summary, .newReplies(count: 2))

        await engine.setFidFilter("50", enabled: false)
        let fetchCountBeforeDisabledRun = fetchedThreadIDs.count
        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)
        XCTAssertEqual(fetchedThreadIDs.count, fetchCountBeforeDisabledRun)
        XCTAssertEqual(engine.snapshot?.totalCount, 0)
    }

    func testUpdateCheckReportsFetchFailureAsFailedNotSkipped() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-updates-failure")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let favoriteUpdateStore = FavoriteUpdateStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "favorite-updates"
        )
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "961")
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "更新检测失败")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "失败主题",
            sourceGroup: .forumBoard(id: "51", label: "测试板块"),
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let engine = try makeUpdateCheckEngine(
            updateStore: favoriteUpdateStore,
            libraryStore: localFavoriteLibraryStore,
            // A non-offline failure (e.g. a parse error) is a genuine
            // per-target failure, unlike `YamiboError.offline` — see
            // `testUpdateCheckTreatsOfflineFetchFailureAsRunLevelSkipNotTargetFailure`
            // below for that distinct offline-specific contract.
            pageFetcher: { _ in throw YamiboError.parsingFailed(context: "test") }
        )
        await engine.load()

        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)

        XCTAssertEqual(engine.snapshot?.failedCount, 1)
        XCTAssertEqual(engine.snapshot?.skippedCount, 0)
    }

    /// A network-unreachable fetch failure must not count toward any
    /// target's circuit-breaker `consecutiveFailures`, and must abort the
    /// rest of the run immediately instead of grinding through every
    /// remaining candidate the same way — both pinned here across two
    /// favorites, only the first of which the fetcher is ever asked for.
    func testUpdateCheckTreatsOfflineFetchFailureAsRunLevelSkipNotTargetFailure() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-updates-offline")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let favoriteUpdateStore = FavoriteUpdateStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "favorite-updates"
        )
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "离线检测")
        document.upsertItem(try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "970"),
            title: "离线主题一",
            sourceGroup: .forumBoard(id: "52", label: "测试板块"),
            locations: [.category(category.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "971"),
            title: "离线主题二",
            sourceGroup: .forumBoard(id: "52", label: "测试板块"),
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        var fetchedThreadIDs: [String] = []
        let engine = try makeUpdateCheckEngine(
            updateStore: favoriteUpdateStore,
            libraryStore: localFavoriteLibraryStore,
            pageFetcher: { item in
                let threadID = try XCTUnwrap(item.target.threadID)
                fetchedThreadIDs.append(threadID)
                throw YamiboError.offline
            }
        )
        await engine.load()

        _ = await engine.startCheck()
        try await waitForStatus(.failed, in: engine)

        XCTAssertEqual(fetchedThreadIDs.count, 1)
        XCTAssertEqual(engine.snapshot?.failedCount, 0)
        XCTAssertEqual(engine.snapshot?.errorMessage, YamiboError.offline.localizedDescription)

        let state = await favoriteUpdateStore.loadState()
        XCTAssertEqual(state.trackedTargets.count, 2)
        XCTAssertTrue(state.trackedTargets.allSatisfy { $0.consecutiveFailures == 0 && $0.lastCheckedAt == nil })
    }

    /// A check run holds an in-memory snapshot of the event list for its
    /// whole (minutes-long) duration and commits it at the end. Store writes
    /// that land in between — the user marking an event read or dismissed
    /// from the updates page, another writer inserting an event or tracked
    /// target — must survive that commit instead of being rolled back by the
    /// stale snapshot.
    func testCommitPreservesMidRunUserEventOperationsAndStoreOnlyWrites() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-updates-midrun")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let favoriteUpdateStore = FavoriteUpdateStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "favorite-updates"
        )
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "960")
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "运行中操作")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "更新主题",
            sourceGroup: .forumBoard(id: "50", label: "测试板块"),
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        var pages = [
            try makeThreadPage(threadID: "960", postID: "p1", title: "更新主题", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", title: "更新主题", replyCount: 3, pageCount: 1)
        ]
        var fetchCount = 0
        var gateReached = false
        var gateOpen = false
        let engine = try makeUpdateCheckEngine(
            updateStore: favoriteUpdateStore,
            libraryStore: localFavoriteLibraryStore,
            pageFetcher: { _ in
                fetchCount += 1
                let page = pages.removeFirst()
                if fetchCount == 2 {
                    gateReached = true
                    while !gateOpen {
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                }
                return page
            }
        )
        await engine.load()

        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)

        let readEvent = FavoriteUpdateEvent(
            target: .favorite(FavoriteItemTarget(kind: .normalThread, threadID: "961")),
            title: "已读主题",
            mode: .normalThread,
            summary: .newReplies(count: 1)
        )
        let dismissedEvent = FavoriteUpdateEvent(
            target: .favorite(FavoriteItemTarget(kind: .normalThread, threadID: "962")),
            title: "忽略主题",
            mode: .normalThread,
            summary: .newReplies(count: 1)
        )
        try await favoriteUpdateStore.insertEvent(readEvent)
        try await favoriteUpdateStore.insertEvent(dismissedEvent)

        _ = await engine.startCheck()
        for _ in 0..<100 where !gateReached {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(gateReached)

        try await favoriteUpdateStore.markEventRead(readEvent.id)
        try await favoriteUpdateStore.dismissEvent(dismissedEvent.id)
        let storeOnlyEvent = FavoriteUpdateEvent(
            target: .favorite(FavoriteItemTarget(kind: .normalThread, threadID: "963")),
            title: "并发主题",
            mode: .normalThread,
            summary: .newReplies(count: 2)
        )
        try await favoriteUpdateStore.insertEvent(storeOnlyEvent)
        let storeOnlyTarget = FavoriteUpdateTrackedTarget(
            target: .favorite(FavoriteItemTarget(kind: .normalThread, threadID: "999")),
            title: "并发目标",
            mode: .normalThread
        )
        try await favoriteUpdateStore.upsertTrackedTarget(storeOnlyTarget)
        gateOpen = true
        try await waitForStatus(.completed, in: engine)

        let state = await favoriteUpdateStore.loadState()
        let persistedRead = try XCTUnwrap(state.events.first { $0.id == readEvent.id })
        XCTAssertNotNil(persistedRead.readAt)
        XCTAssertNil(persistedRead.dismissedAt)
        let persistedDismissed = try XCTUnwrap(state.events.first { $0.id == dismissedEvent.id })
        XCTAssertNotNil(persistedDismissed.dismissedAt)
        XCTAssertNotNil(state.events.first { $0.id == storeOnlyEvent.id })
        let detected = try XCTUnwrap(state.events.first { $0.target == .favorite(target) })
        XCTAssertEqual(detected.summary, .newReplies(count: 2))
        XCTAssertNil(detected.readAt)
        XCTAssertNil(detected.dismissedAt)
        XCTAssertTrue(state.trackedTargets.contains { $0.id == storeOnlyTarget.id })
        XCTAssertTrue(state.trackedTargets.contains { $0.id == target.id })
        XCTAssertEqual(Set(engine.events.map(\.id)), [readEvent.id, storeOnlyEvent.id, detected.id])
    }

    /// When the user dismisses a target's event mid-run and the same run then
    /// detects further updates for that target, the run's in-memory
    /// accumulation replaces the old event under a fresh id — so the commit
    /// must keep the old event dismissed while surfacing the new detection.
    func testMidRunDismissalOfSupersededEventStaysDismissedWhileNewDetectionSurfaces() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-updates-supersede")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let favoriteUpdateStore = FavoriteUpdateStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "favorite-updates"
        )
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "960")
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "运行中忽略")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "更新主题",
            sourceGroup: .forumBoard(id: "50", label: "测试板块"),
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        var pages = [
            try makeThreadPage(threadID: "960", postID: "p1", title: "更新主题", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", title: "更新主题", replyCount: 3, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p3", title: "更新主题", replyCount: 4, pageCount: 1)
        ]
        var fetchCount = 0
        var gateReached = false
        var gateOpen = false
        let engine = try makeUpdateCheckEngine(
            updateStore: favoriteUpdateStore,
            libraryStore: localFavoriteLibraryStore,
            pageFetcher: { _ in
                fetchCount += 1
                let page = pages.removeFirst()
                if fetchCount == 3 {
                    gateReached = true
                    while !gateOpen {
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                }
                return page
            }
        )
        await engine.load()

        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)
        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)
        let firstEventID = try XCTUnwrap(engine.events.first?.id)
        XCTAssertEqual(engine.events.first?.summary, .newReplies(count: 2))

        _ = await engine.startCheck()
        for _ in 0..<100 where !gateReached {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(gateReached)

        try await favoriteUpdateStore.dismissEvent(firstEventID)
        gateOpen = true
        try await waitForStatus(.completed, in: engine)

        let state = await favoriteUpdateStore.loadState()
        let dismissed = try XCTUnwrap(state.events.first { $0.id == firstEventID })
        XCTAssertNotNil(dismissed.dismissedAt)
        let replacement = try XCTUnwrap(state.events.first { $0.target == .favorite(target) && $0.dismissedAt == nil })
        XCTAssertNotEqual(replacement.id, firstEventID)
        XCTAssertNil(replacement.readAt)
        XCTAssertEqual(replacement.summary, .newReplies(count: 3))
        XCTAssertEqual(engine.events.map(\.id), [replacement.id])
    }

    /// Regression guard for the `.mangaTitle` dead-case cleanup. Two facts
    /// pinned here: the mode label now mirrors `FavoriteItemTargetKind`
    /// faithfully (`init(kind:)` is total — no more ternary stamping
    /// `.normalThread` on everything non-novel), and manga-thread favorites
    /// remain EXCLUDED from update checking by `candidates(in:)`, which is
    /// why `.mangaThread` is documented as unreached at runtime.
    func testUpdateCheckExcludesMangaThreadFavoritesAndModeMappingStaysFaithful() async throws {
        XCTAssertEqual(FavoriteUpdateTargetMode(kind: .normalThread), .normalThread)
        XCTAssertEqual(FavoriteUpdateTargetMode(kind: .novelThread), .novelThread)
        XCTAssertEqual(FavoriteUpdateTargetMode(kind: .mangaThread), .mangaThread)

        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-updates-manga-mode")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let favoriteUpdateStore = FavoriteUpdateStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "favorite-updates"
        )
        let target = FavoriteItemTarget(kind: .mangaThread, threadID: "962")
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "漫画更新检测")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "漫画主题",
            sourceGroup: .forumBoard(id: "30", label: "漫画板块"),
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let page = try makeThreadPage(threadID: "962", postID: "p1", title: "漫画主题", replyCount: 1, pageCount: 1)
        let engine = try makeUpdateCheckEngine(
            updateStore: favoriteUpdateStore,
            libraryStore: localFavoriteLibraryStore,
            pageFetcher: { _ in page }
        )
        await engine.load()

        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)

        let state = await favoriteUpdateStore.loadState()
        XCTAssertTrue(state.trackedTargets.isEmpty)
        XCTAssertEqual(engine.snapshot?.totalCount, 0)
    }

    // The smart-manga interval Picker's setter/getter round-trip: separate
    // storage from `updateCheckInterval` (the thread-check lane's own
    // interval), so setting one must never perturb the other.
    func testConfiguredMangaIntervalRoundTripsThroughSettingsIndependentlyOfThreadInterval() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-updates-manga-interval")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let favoriteUpdateStore = FavoriteUpdateStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "favorite-updates"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let engine = try makeUpdateCheckEngine(
            updateStore: favoriteUpdateStore,
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore
        )

        let defaultInterval = await engine.configuredMangaInterval()
        XCTAssertEqual(defaultInterval, .threeDays)

        await engine.setConfiguredMangaInterval(.week)
        await engine.setConfiguredInterval(.day)

        let updatedMangaInterval = await engine.configuredMangaInterval()
        let updatedThreadInterval = await engine.configuredInterval()
        XCTAssertEqual(updatedMangaInterval, .week)
        XCTAssertEqual(updatedThreadInterval, .day)
    }

    private func waitForStatus(
        _ status: FavoriteUpdateRunStatus,
        in engine: FavoriteUpdateCheckEngine
    ) async throws {
        do {
            try await waitForMainActorCondition(timeout: .seconds(1), pollInterval: .milliseconds(10)) {
                engine.snapshot?.status == status
            }
        } catch is TestWaitTimeoutError {
            XCTFail("Timed out waiting for favorite update status \(status)")
        }
    }
}

/// Builds a `FavoriteUpdateCheckEngine` backed by isolated per-test stores.
@MainActor
private func makeUpdateCheckEngine(
    updateStore: FavoriteUpdateStore,
    libraryStore: FavoriteLibraryStore,
    pageFetcher: ((FavoriteItem) async throws -> ForumThreadPage)? = nil,
    settingsStore: SettingsStore? = nil,
    mangaDirectoryStore: (any MangaDirectoryPersisting)? = nil,
    makeMangaDirectoryWorkflow: (@Sendable (_ searchForumID: String) async -> MangaDirectoryWorkflow)? = nil,
    // Optional-with-nil rather than a constructed default: default-argument
    // expressions evaluate outside the function's @MainActor isolation, so a
    // direct `= FavoriteUpdateActiveRunRegistry()` does not compile.
    runRegistry: FavoriteUpdateActiveRunRegistry? = nil
) throws -> FavoriteUpdateCheckEngine {
    let runRegistry = runRegistry ?? FavoriteUpdateActiveRunRegistry()
    let suiteName = YamiboTestDefaults.suiteName(prefix: "favorite-update-check-engine-deps")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let sessionStore = SessionStore(defaults: defaults, key: "session")
    let urlSession = YamiboNetworkConfiguration.makeSession()
    let forumCacheStore = ForumCacheStore(
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    )
    return FavoriteUpdateCheckEngine(
        updateStore: updateStore,
        libraryStore: libraryStore,
        makeForumThreadReaderRepository: {
            let sessionState = await sessionStore.load()
            let client = YamiboClient(
                session: urlSession,
                cookie: sessionState.cookie,
                userAgent: sessionState.userAgent
            )
            return ForumThreadReaderRepository(client: client, cacheStore: forumCacheStore)
        },
        settingsStore: settingsStore,
        pageFetcher: pageFetcher,
        mangaDirectoryStore: mangaDirectoryStore,
        makeMangaDirectoryWorkflow: makeMangaDirectoryWorkflow,
        runRegistry: runRegistry
    )
}

// MARK: - Smart-manga directory check lane

@MainActor
final class FavoriteUpdateCheckEngineSmartMangaTests: XCTestCase {
    private func makeSettingsStore(
        smartModeForumIDs: Set<String>,
        interval: SmartMangaUpdateCheckInterval = .day
    ) async throws -> SettingsStore {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "smart-manga-update-settings")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let store = SettingsStore(defaults: defaults, key: "settings")
        var boardReader = BoardReaderSettings(entries: [:])
        for fid in smartModeForumIDs {
            boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: fid)
        }
        var favorites = FavoriteLibrarySettings()
        favorites.smartMangaUpdateCheckInterval = interval
        try await store.save(AppSettings(favorites: favorites, boardReader: boardReader))
        return store
    }

    private func makeFavoritesDocument(mangaItems: [(tid: String, forumID: String, forumName: String)]) throws -> FavoriteLibraryDocument {
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "智能漫画更新检测")
        for (tid, forumID, forumName) in mangaItems {
            document.upsertItem(try FavoriteItem(
                target: .mangaThread(threadID: tid),
                title: "漫画收藏-\(tid)",
                sourceGroup: .forumBoard(id: forumID, label: forumName),
                forumID: forumID,
                forumName: forumName,
                locations: [.category(category.id)]
            ))
        }
        return document
    }

    private func waitForStatus(
        _ status: FavoriteUpdateRunStatus,
        in engine: FavoriteUpdateCheckEngine
    ) async throws {
        do {
            try await waitForMainActorCondition(timeout: .seconds(1), pollInterval: .milliseconds(10)) {
                engine.snapshot?.status == status
            }
        } catch is TestWaitTimeoutError {
            XCTFail("Timed out waiting for favorite update status \(status)")
        }
    }

    /// Backdates a tracked directory target's `lastCheckedAt` far enough
    /// into the past that it's due again under any of this test file's
    /// intervals, without needing to actually wait real time.
    private func backdateLastCheckedAt(
        cleanBookName: String,
        in updateStore: FavoriteUpdateStore
    ) async throws {
        let state = await updateStore.loadState()
        guard var target = state.trackedTargets.first(where: { $0.target == .mangaDirectory(cleanBookName: cleanBookName) }) else {
            XCTFail("Expected an existing tracked target for \(cleanBookName)")
            return
        }
        target.lastCheckedAt = Date.now.addingTimeInterval(-30 * 24 * 3600)
        try await updateStore.upsertTrackedTarget(target)
    }

    func testEligibilityGateExcludesModeOffAndUnresolvedThenSeedsResolvedGroupWithoutAnEvent() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "smart-manga-eligibility")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let libraryStore = FavoriteLibraryStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "local-favorites")
        let updateStore = FavoriteUpdateStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "favorite-updates")
        let settingsStore = try await makeSettingsStore(smartModeForumIDs: ["30"])

        // "5001"/"5002" are mode-on and both resolve to the same directory —
        // they must collapse into ONE tracked target. "5003" is mode-off
        // (fid "46" has no smart entry). "5004" is mode-on but its tid was
        // never resolved into any directory.
        let document = try makeFavoritesDocument(mangaItems: [
            ("5001", "30", "智能漫画板块"),
            ("5002", "30", "智能漫画板块"),
            ("5003", "46", "普通漫画板块"),
            ("5004", "30", "智能漫画板块"),
        ])
        try await libraryStore.save(document)

        let directoryStore = RecordingMangaDirectoryStore(directories: [
            MangaDirectory(
                cleanBookName: "合并测试漫画",
                strategy: .tag,
                sourceKey: "31",
                chapters: [makeChapter(tid: "5001", title: "第1话", chapterNumber: 1), makeChapter(tid: "5002", title: "第2话", chapterNumber: 2)]
            ),
        ])
        let repository = RecordingMangaDirectoryRepository()

        let engine = try makeUpdateCheckEngine(
            updateStore: updateStore,
            libraryStore: libraryStore,
            settingsStore: settingsStore,
            mangaDirectoryStore: directoryStore,
            makeMangaDirectoryWorkflow: { forumID in
                MangaDirectoryWorkflow(repository: repository, store: directoryStore, configuration: MangaDirectoryWorkflowConfiguration(searchForumID: forumID))
            }
        )
        await engine.load()
        _ = await engine.startCheck()
        try await waitForStatus(.completed, in: engine)

        let state = await updateStore.loadState()
        let mangaTargets = state.trackedTargets.filter { $0.mode == .mangaDirectory }
        XCTAssertEqual(mangaTargets.count, 1)
        XCTAssertEqual(mangaTargets.first?.target, .mangaDirectory(cleanBookName: "合并测试漫画"))
        XCTAssertEqual(mangaTargets.first?.knownChapterTIDs, ["5001", "5002"])
        XCTAssertTrue(mangaTargets.first?.baselineReady ?? false)
        // First sighting: baseline seeding must be zero-network and must not
        // create an event.
        let tagRequests = await repository.tagRequestCount
        let searchRequests = await repository.searchRequestCount
        XCTAssertEqual(tagRequests, 0)
        XCTAssertEqual(searchRequests, 0)
        XCTAssertTrue(engine.events.filter { $0.mode == .mangaDirectory }.isEmpty)
    }

    func testNewChapterDetectionMergesFavoritesAndBaselineNeverShrinksAcrossRetentionPruning() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "smart-manga-new-chapters")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let libraryStore = FavoriteLibraryStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "local-favorites")
        let updateStore = FavoriteUpdateStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "favorite-updates")
        let settingsStore = try await makeSettingsStore(smartModeForumIDs: ["30"])

        let document = try makeFavoritesDocument(mangaItems: [
            ("6001", "30", "智能漫画板块"),
            ("6002", "30", "智能漫画板块"),
        ])
        try await libraryStore.save(document)

        let directoryStore = RecordingMangaDirectoryStore(directories: [
            MangaDirectory(
                cleanBookName: "连载测试漫画",
                strategy: .tag,
                sourceKey: "31",
                chapters: [makeChapter(tid: "6001", title: "普通帖子", chapterNumber: 1), makeChapter(tid: "6002", title: "第2话", chapterNumber: 2)]
            ),
        ])
        let repository = RecordingMangaDirectoryRepository(
            tagChapters: [
                makeChapter(tid: "6001", title: "普通帖子", chapterNumber: 1),
                makeChapter(tid: "6002", title: "第2话", chapterNumber: 2),
                makeChapter(tid: "6003", title: "第3话", chapterNumber: 3),
            ]
        )

        // Shared across this test's engines: co-resident engines must share
        // one run registry (see the engine's `runRegistry` doc; production
        // wires one shared instance) or an idle sibling draining the change
        // stream mistakes the live run for an orphan and races its
        // interrupted-downgrade write against that run's own terminal save.
        let runRegistry = FavoriteUpdateActiveRunRegistry()

        func makeEngine() throws -> FavoriteUpdateCheckEngine {
            try makeUpdateCheckEngine(
                updateStore: updateStore,
                libraryStore: libraryStore,
                settingsStore: settingsStore,
                mangaDirectoryStore: directoryStore,
                makeMangaDirectoryWorkflow: { forumID in
                    MangaDirectoryWorkflow(repository: repository, store: directoryStore, configuration: MangaDirectoryWorkflowConfiguration(searchForumID: forumID))
                },
                runRegistry: runRegistry
            )
        }

        // Run 1: seeds the baseline from the two favorited chapters, no
        // network, no event.
        let firstEngine = try makeEngine()
        await firstEngine.load()
        _ = await firstEngine.startCheck()
        try await waitForStatus(.completed, in: firstEngine)
        XCTAssertTrue(firstEngine.events.filter { $0.mode == .mangaDirectory }.isEmpty)

        // Run 2: due; the workflow's tag refresh finds a new chapter "6003"
        // — ONE merged event for the directory, not one per favorite.
        try await backdateLastCheckedAt(cleanBookName: "连载测试漫画", in: updateStore)
        let secondEngine = try makeEngine()
        await secondEngine.load()
        _ = await secondEngine.startCheck()
        try await waitForStatus(.completed, in: secondEngine)

        let mangaEvents = secondEngine.events.filter { $0.mode == .mangaDirectory }
        XCTAssertEqual(mangaEvents.count, 1)
        XCTAssertEqual(mangaEvents.first?.target, .mangaDirectory(cleanBookName: "连载测试漫画"))
        XCTAssertEqual(mangaEvents.first?.summary, .newChapters(count: 1))
        XCTAssertEqual(mangaEvents.first?.detailIDs, ["6003"])

        var state = await updateStore.loadState()
        var tracked = try XCTUnwrap(state.trackedTargets.first { $0.target == .mangaDirectory(cleanBookName: "连载测试漫画") })
        XCTAssertEqual(tracked.knownChapterTIDs, ["6001", "6002", "6003"])

        // Run 3: the directory's own retention logic prunes "6001" from what
        // the workflow returns (simulating `MangaDirectoryChapterRetention`)
        // — the tracked baseline must NOT shrink in lockstep.
        try await backdateLastCheckedAt(cleanBookName: "连载测试漫画", in: updateStore)
        await repository.setTagChapters([
            makeChapter(tid: "6002", title: "第2话", chapterNumber: 2),
            makeChapter(tid: "6003", title: "第3话", chapterNumber: 3),
        ])
        let thirdEngine = try makeEngine()
        await thirdEngine.load()
        _ = await thirdEngine.startCheck()
        try await waitForStatus(.completed, in: thirdEngine)
        let thirdRunMangaEvents = thirdEngine.events.filter { $0.mode == .mangaDirectory && $0.dismissedAt == nil }
        XCTAssertEqual(thirdRunMangaEvents.count, 1, "pruning must not fabricate a spurious new-chapter event")
        XCTAssertEqual(thirdRunMangaEvents.first?.summary, .newChapters(count: 1), "the run-2 event must stay unchanged, not merged with a zero delta")

        state = await updateStore.loadState()
        tracked = try XCTUnwrap(state.trackedTargets.first { $0.target == .mangaDirectory(cleanBookName: "连载测试漫画") })
        XCTAssertEqual(tracked.knownChapterTIDs, ["6001", "6002", "6003"], "baseline must not shrink when the directory prunes a stale chapter")

        // Run 4: "6001" reappears in what the workflow returns — because the
        // baseline never dropped it, this must NOT falsely re-report as new.
        try await backdateLastCheckedAt(cleanBookName: "连载测试漫画", in: updateStore)
        await repository.setTagChapters([
            makeChapter(tid: "6001", title: "普通帖子", chapterNumber: 1),
            makeChapter(tid: "6002", title: "第2话", chapterNumber: 2),
            makeChapter(tid: "6003", title: "第3话", chapterNumber: 3),
        ])
        let fourthEngine = try makeEngine()
        await fourthEngine.load()
        _ = await fourthEngine.startCheck()
        try await waitForStatus(.completed, in: fourthEngine)
        // Still just the run-2-detected event (accumulated), no fresh
        // "6001 is new" report.
        let finalEvents = fourthEngine.events.filter { $0.mode == .mangaDirectory && $0.dismissedAt == nil }
        XCTAssertEqual(finalEvents.count, 1)
        XCTAssertEqual(finalEvents.first?.summary, .newChapters(count: 1))
    }

    func testCooldownAndFloodControlSkipsDoNotAdvanceBaselineOrTripCircuitBreaker() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "smart-manga-cooldown")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let libraryStore = FavoriteLibraryStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "local-favorites")
        let updateStore = FavoriteUpdateStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "favorite-updates")
        let settingsStore = try await makeSettingsStore(smartModeForumIDs: ["30"])

        let document = try makeFavoritesDocument(mangaItems: [("7001", "30", "智能漫画板块")])
        try await libraryStore.save(document)

        // `.links` (non-`.tag`) strategy always goes through the
        // search-cooldown-guarded path.
        let directoryStore = RecordingMangaDirectoryStore(directories: [
            MangaDirectory(
                cleanBookName: "冷却测试漫画",
                strategy: .links,
                sourceKey: "冷却测试漫画",
                chapters: [makeChapter(tid: "7001", title: "第1话", chapterNumber: 1)]
            ),
        ])
        let repository = RecordingMangaDirectoryRepository(searchError: YamiboError.floodControl)

        // Shared across this test's engines: co-resident engines must share
        // one run registry (see the engine's `runRegistry` doc; production
        // wires one shared instance) or an idle sibling draining the change
        // stream mistakes the live run for an orphan and races its
        // interrupted-downgrade write against that run's own terminal save.
        let runRegistry = FavoriteUpdateActiveRunRegistry()

        func makeEngine() throws -> FavoriteUpdateCheckEngine {
            try makeUpdateCheckEngine(
                updateStore: updateStore,
                libraryStore: libraryStore,
                settingsStore: settingsStore,
                mangaDirectoryStore: directoryStore,
                makeMangaDirectoryWorkflow: { forumID in
                    MangaDirectoryWorkflow(repository: repository, store: directoryStore, configuration: MangaDirectoryWorkflowConfiguration(searchForumID: forumID))
                },
                runRegistry: runRegistry
            )
        }

        let firstEngine = try makeEngine()
        await firstEngine.load()
        _ = await firstEngine.startCheck()
        try await waitForStatus(.completed, in: firstEngine)

        try await backdateLastCheckedAt(cleanBookName: "冷却测试漫画", in: updateStore)
        let stateBeforeSkip = await updateStore.loadState()
        let beforeSkip = try XCTUnwrap(stateBeforeSkip.trackedTargets.first { $0.target == .mangaDirectory(cleanBookName: "冷却测试漫画") })

        let secondEngine = try makeEngine()
        await secondEngine.load()
        _ = await secondEngine.startCheck()
        try await waitForStatus(.completed, in: secondEngine)

        XCTAssertTrue(secondEngine.events.filter { $0.mode == .mangaDirectory }.isEmpty)
        let stateAfterSkip = await updateStore.loadState()
        let afterSkip = try XCTUnwrap(stateAfterSkip.trackedTargets.first { $0.target == .mangaDirectory(cleanBookName: "冷却测试漫画") })
        // A cooldown/flood-control hit is a pure skip: nothing about the
        // tracked target changes, in contrast to a real failure below.
        XCTAssertEqual(afterSkip.knownChapterTIDs, beforeSkip.knownChapterTIDs)
        XCTAssertEqual(afterSkip.consecutiveFailures, 0)
        XCTAssertEqual(afterSkip.lastCheckedAt, beforeSkip.lastCheckedAt)

        // Contrast: a real (non-cooldown, non-flood) failure DOES feed the
        // circuit breaker.
        await repository.setSearchError(YamiboError.underlying("boom"))
        try await backdateLastCheckedAt(cleanBookName: "冷却测试漫画", in: updateStore)
        let thirdEngine = try makeEngine()
        await thirdEngine.load()
        _ = await thirdEngine.startCheck()
        try await waitForStatus(.completed, in: thirdEngine)

        let stateAfterRealFailure = await updateStore.loadState()
        let afterRealFailure = try XCTUnwrap(stateAfterRealFailure.trackedTargets.first { $0.target == .mangaDirectory(cleanBookName: "冷却测试漫画") })
        XCTAssertEqual(afterRealFailure.consecutiveFailures, 1)
        XCTAssertNotNil(afterRealFailure.lastError)
    }

    func testNonTagDirectoryCapLimitsHowManySearchTriggeringGroupsRunPerCheck() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "smart-manga-cap")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let libraryStore = FavoriteLibraryStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "local-favorites")
        let updateStore = FavoriteUpdateStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "favorite-updates")
        let settingsStore = try await makeSettingsStore(smartModeForumIDs: ["30"])

        let document = try makeFavoritesDocument(mangaItems: [
            ("8001", "30", "智能漫画板块"),
            ("8002", "30", "智能漫画板块"),
        ])
        try await libraryStore.save(document)

        let directoryStore = RecordingMangaDirectoryStore(directories: [
            MangaDirectory(cleanBookName: "非标签漫画A", strategy: .links, sourceKey: "非标签漫画A", chapters: [makeChapter(tid: "8001", title: "第1话", chapterNumber: 1)]),
            MangaDirectory(cleanBookName: "非标签漫画B", strategy: .links, sourceKey: "非标签漫画B", chapters: [makeChapter(tid: "8002", title: "第1话", chapterNumber: 1)]),
        ])
        let repository = RecordingMangaDirectoryRepository(
            searchChapters: [makeChapter(tid: "8001", title: "第1话", chapterNumber: 1)]
        )

        // Shared across this test's engines: co-resident engines must share
        // one run registry (see the engine's `runRegistry` doc; production
        // wires one shared instance) or an idle sibling draining the change
        // stream mistakes the live run for an orphan and races its
        // interrupted-downgrade write against that run's own terminal save.
        let runRegistry = FavoriteUpdateActiveRunRegistry()

        func makeEngine() throws -> FavoriteUpdateCheckEngine {
            try makeUpdateCheckEngine(
                updateStore: updateStore,
                libraryStore: libraryStore,
                settingsStore: settingsStore,
                mangaDirectoryStore: directoryStore,
                makeMangaDirectoryWorkflow: { forumID in
                    MangaDirectoryWorkflow(repository: repository, store: directoryStore, configuration: MangaDirectoryWorkflowConfiguration(searchForumID: forumID))
                },
                runRegistry: runRegistry
            )
        }

        let firstEngine = try makeEngine()
        await firstEngine.load()
        _ = await firstEngine.startCheck()
        try await waitForStatus(.completed, in: firstEngine)

        try await backdateLastCheckedAt(cleanBookName: "非标签漫画A", in: updateStore)
        try await backdateLastCheckedAt(cleanBookName: "非标签漫画B", in: updateStore)

        let secondEngine = try makeEngine()
        await secondEngine.load()
        _ = await secondEngine.startCheck(nonTagMangaDirectoryCheckCap: 1)
        try await waitForStatus(.completed, in: secondEngine)

        // Cap of 1: exactly one non-tag directory's search actually ran.
        let searchRequests = await repository.searchRequestCount
        XCTAssertEqual(searchRequests, 1)

        let state = await updateStore.loadState()
        let trackedIDs: Set<String> = [
            FavoriteUpdateTargetKey.mangaDirectory(cleanBookName: "非标签漫画A").id,
            FavoriteUpdateTargetKey.mangaDirectory(cleanBookName: "非标签漫画B").id,
        ]
        let checkedCount = state.trackedTargets
            .filter { trackedIDs.contains($0.target.id) }
            .filter { target in
                guard let lastCheckedAt = target.lastCheckedAt else { return false }
                return Date.now.timeIntervalSince(lastCheckedAt) < 24 * 3600
            }
            .count
        XCTAssertEqual(checkedCount, 1, "only the cap's worth of non-tag groups should have advanced lastCheckedAt this run")
    }

    /// Regression guard: the `.tag`-strategy lane must stop at the first
    /// cooldown/flood-control skip in the same run, matching the non-tag
    /// lane's existing behavior — otherwise every other due `.tag` group
    /// that also falls back to a live search fires a real HTTP request in
    /// the same run, even though the forum already flood-controlled the
    /// first one.
    func testTagDueLoopStopsAfterCooldownSkipSoLaterTagDirectoriesAreNeverChecked() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "smart-manga-tag-cooldown-break")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let libraryStore = FavoriteLibraryStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "local-favorites")
        let updateStore = FavoriteUpdateStore(defaults: try YamiboTestDefaults.defaults(suiteName: suiteName), key: "favorite-updates")
        let settingsStore = try await makeSettingsStore(smartModeForumIDs: ["30"])

        let document = try makeFavoritesDocument(mangaItems: [
            ("9001", "30", "智能漫画板块"),
            ("9002", "30", "智能漫画板块"),
        ])
        try await libraryStore.save(document)

        // Two `.tag`-strategy directories, both due, both with an empty
        // tag-page result so both fall back to a live search — the exact
        // shape that lets a flood-control hit on the first one leak into a
        // second real request for the second one if the loop doesn't break.
        let directoryStore = RecordingMangaDirectoryStore(directories: [
            MangaDirectory(cleanBookName: "标签漫画A", strategy: .tag, sourceKey: "40", chapters: [makeChapter(tid: "9001", title: "第1话", chapterNumber: 1)]),
            MangaDirectory(cleanBookName: "标签漫画B", strategy: .tag, sourceKey: "41", chapters: [makeChapter(tid: "9002", title: "第1话", chapterNumber: 1)]),
        ])
        let repository = RecordingMangaDirectoryRepository(searchError: YamiboError.floodControl)

        // Shared across this test's engines: co-resident engines must share
        // one run registry (see the engine's `runRegistry` doc; production
        // wires one shared instance) or an idle sibling draining the change
        // stream mistakes the live run for an orphan and races its
        // interrupted-downgrade write against that run's own terminal save.
        let runRegistry = FavoriteUpdateActiveRunRegistry()

        func makeEngine() throws -> FavoriteUpdateCheckEngine {
            try makeUpdateCheckEngine(
                updateStore: updateStore,
                libraryStore: libraryStore,
                settingsStore: settingsStore,
                mangaDirectoryStore: directoryStore,
                makeMangaDirectoryWorkflow: { forumID in
                    MangaDirectoryWorkflow(repository: repository, store: directoryStore, configuration: MangaDirectoryWorkflowConfiguration(searchForumID: forumID))
                },
                runRegistry: runRegistry
            )
        }

        // Run 1: seeds both baselines, zero network.
        let firstEngine = try makeEngine()
        await firstEngine.load()
        _ = await firstEngine.startCheck()
        try await waitForStatus(.completed, in: firstEngine)
        let tagRequestsAfterSeed = await repository.tagRequestCount
        let searchRequestsAfterSeed = await repository.searchRequestCount
        XCTAssertEqual(tagRequestsAfterSeed, 0)
        XCTAssertEqual(searchRequestsAfterSeed, 0)

        try await backdateLastCheckedAt(cleanBookName: "标签漫画A", in: updateStore)
        try await backdateLastCheckedAt(cleanBookName: "标签漫画B", in: updateStore)

        // Run 2: both are due `.tag` groups, processed in cleanBookName
        // order ("标签漫画A" before "标签漫画B"). A's empty tag result falls
        // back to a search that hits flood control; B must never even be
        // attempted.
        let secondEngine = try makeEngine()
        await secondEngine.load()
        _ = await secondEngine.startCheck()
        try await waitForStatus(.completed, in: secondEngine)

        let tagRequestsAfterRun2 = await repository.tagRequestCount
        let searchRequestsAfterRun2 = await repository.searchRequestCount
        XCTAssertEqual(tagRequestsAfterRun2, 1, "the second tag directory's tag-page lookup must never fire once the first hit flood control")
        XCTAssertEqual(searchRequestsAfterRun2, 1, "the second tag directory's fallback search must never fire once the first hit flood control")
        XCTAssertTrue(secondEngine.events.filter { $0.mode == .mangaDirectory }.isEmpty)
        XCTAssertEqual(secondEngine.snapshot?.skippedCount, 1, "only the first group should be recorded as skipped this run")

        let state = await updateStore.loadState()
        let trackedB = try XCTUnwrap(state.trackedTargets.first { $0.target == .mangaDirectory(cleanBookName: "标签漫画B") })
        XCTAssertEqual(trackedB.consecutiveFailures, 0, "an untouched group must not have its circuit breaker advanced either")
    }
}

private func makeChapter(tid: String, title: String, chapterNumber: Double) -> MangaChapter {
    MangaChapter(tid: tid, rawTitle: title, chapterNumber: chapterNumber)
}

private actor RecordingMangaDirectoryStore: MangaDirectoryPersisting {
    private var directories: [String: MangaDirectory]

    init(directories: [MangaDirectory] = []) {
        self.directories = Dictionary(uniqueKeysWithValues: directories.map { ($0.cleanBookName, $0) })
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        directories[name.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        let normalized = tid.trimmingCharacters(in: .whitespacesAndNewlines)
        return directories.values.first { $0.chapters.contains { $0.tid == normalized } }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {
        directories[directory.cleanBookName] = directory
    }

    func deleteDirectory(named name: String) async throws {
        directories.removeValue(forKey: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private actor RecordingMangaDirectoryRepository: MangaDirectoryRepository {
    private var tagChapters: [MangaChapter]
    private var searchChapters: [MangaChapter]
    private var searchError: Error?
    private(set) var tagRequestCount = 0
    private(set) var searchRequestCount = 0

    init(tagChapters: [MangaChapter] = [], searchChapters: [MangaChapter] = [], searchError: Error? = nil) {
        self.tagChapters = tagChapters
        self.searchChapters = searchChapters
        self.searchError = searchError
    }

    func setTagChapters(_ chapters: [MangaChapter]) {
        tagChapters = chapters
    }

    func setSearchError(_ error: Error?) {
        searchError = error
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        MangaDirectorySeed(currentChapter: makeChapter(tid: threadID, title: "第1话", chapterNumber: 1), tagIDs: [], cleanBookName: threadID)
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        tagRequestCount += 1
        return tagChapters
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        searchRequestCount += 1
        if let searchError { throw searchError }
        return searchChapters
    }
}

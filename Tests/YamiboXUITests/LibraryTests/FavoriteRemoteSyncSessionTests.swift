import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class FavoriteRemoteSyncSessionTests: XCTestCase {
    func testSnapshotLoadsInterruptsRunningTaskAndPersistsHiddenCard() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-sync-snapshot")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let runStore = FavoriteSyncRunStore(defaults: defaults, key: "sync-runs")
        let runningSnapshot = FavoriteRemoteSyncSnapshot(
            runID: "sync-run",
            status: .running,
            targetCategoryID: FavoriteCategory.defaultID,
            targetCategoryName: "默认",
            phase: .importing,
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_100),
            scannedCount: 2,
            importedCount: 1
        )
        try await runStore.save(runningSnapshot)

        let session = try makeSyncSession(runStore: runStore)
        await session.load()

        XCTAssertEqual(session.snapshot?.runID, "sync-run")
        XCTAssertEqual(session.snapshot?.status, .interrupted)
        XCTAssertEqual(session.snapshot?.warnings, [.taskLost])
        let interrupted = await runStore.latestSnapshot()
        XCTAssertEqual(interrupted?.status, .interrupted)

        await session.hideCard()
        let hidden = await runStore.latestSnapshot()
        XCTAssertTrue(hidden?.isHiddenFromFavoritePage == true)
    }

    func testStartCompletesAndResumeUsesPersistedTargetCategory() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-sync-complete")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let runStore = FavoriteSyncRunStore(defaults: defaults, key: "sync-runs")
        let recorder = FavoriteRemoteSyncTestRecorder()
        let session = try makeSyncSession(
            runStore: runStore,
            runnerOverride: { snapshot, _, persist in
                await recorder.record(snapshot.targetCategoryID)
                var final = snapshot
                final.status = .completed
                final.phase = .completed
                final.importedCount = 2
                final.skippedCount = 1
                final.uploadTargetCount = 1
                final.uploadedCount = 1
                final.failedCount = 1
                final.finishedAt = .now
                await persist(final)
                return final
            }
        )
        await session.load()

        let firstRunID = await session.start(targetCategoryID: FavoriteCategory.defaultID)
        try await waitForStatus(.completed, in: session)
        XCTAssertEqual(session.snapshot?.runID, firstRunID)
        XCTAssertEqual(session.snapshot?.importedCount, 2)
        XCTAssertEqual(session.snapshot?.skippedCount, 1)
        XCTAssertEqual(session.snapshot?.uploadedCount, 1)
        XCTAssertEqual(session.snapshot?.failedCount, 1)

        let secondRunID = await session.resume()
        try await waitForStatus(.completed, in: session)
        XCTAssertNotEqual(secondRunID, firstRunID)
        let recordedCategoryIDs = await recorder.recordedCategoryIDs()
        XCTAssertEqual(recordedCategoryIDs, [FavoriteCategory.defaultID, FavoriteCategory.defaultID])
        let savedStatus = await runStore.latestSnapshot()?.status
        XCTAssertEqual(savedStatus, .completed)
    }

    func testInterruptCancelsRunningTaskAndPersistsInterruptedStatus() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-sync-interrupt")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let runStore = FavoriteSyncRunStore(defaults: defaults, key: "sync-runs")
        let session = try makeSyncSession(
            runStore: runStore,
            runnerOverride: { snapshot, interruptionReason, persist in
                // Emulates the engine's cancellation handling: a cooperative
                // cancellation ends the run as interrupted with the session's
                // provided reason.
                var final = snapshot
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    final.status = .completed
                    final.phase = .completed
                } catch {
                    final.status = .interrupted
                    final.phase = .interrupted
                    final.warnings.append(interruptionReason() ?? .interrupted)
                }
                final.finishedAt = .now
                await persist(final)
                return final
            }
        )
        await session.load()

        _ = await session.start(targetCategoryID: FavoriteCategory.defaultID)
        XCTAssertEqual(session.snapshot?.status, .running)
        await session.interrupt()
        try await waitForStatus(.interrupted, in: session)

        XCTAssertEqual(session.snapshot?.warnings.contains(.interruptedByUser), true)
        XCTAssertNil(session.errorMessage)
        let saved = await runStore.latestSnapshot()
        XCTAssertEqual(saved?.runID, session.snapshot?.runID)
        XCTAssertEqual(saved?.status, .interrupted)
        XCTAssertEqual(saved?.warnings.isEmpty, false)
    }

    /// Gap (smart-comic-mode design doc, Phase G's "遗留 TODO": "`makeEngineRunner()`
    /// 是否正确转发了新依赖给引擎（这条链路目前只在引擎层单测被验证）"): every test
    /// above drives `runnerOverride`, which entirely bypasses `makeEngineRunner()`
    /// — none of them can tell whether `FavoriteRemoteSyncSession` actually
    /// captures and forwards its `mangaDirectoryStore`/`settingsStore` init
    /// parameters into the real `FavoriteYamiboSyncEngine` it constructs. This
    /// test builds a session with no `runnerOverride`, so `start()` runs the
    /// genuine `makeEngineRunner()` path (real `FavoriteRepository`/
    /// `ForumThreadReaderRepository`/`YamiboThreadRouteResolver`, HTTP calls
    /// intercepted by a `URLProtocol` double rather than faked away), and
    /// deliberately turns Smart Comic Mode on for a board (fid 46) that is
    /// *off* by `BoardReaderSettings`'s own default. If the session failed
    /// to forward the injected `settingsStore` (or `mangaDirectoryStore`) into
    /// the engine, the engine would fall back to `BoardReaderSettings()`'s
    /// default (fid 46 off) or to no directory data at all, and the
    /// attribution warning below would never fire — so the warning actually
    /// firing is proof the session-to-engine wiring itself is correct, not
    /// just that the engine's own attribution logic works (Phase G's own
    /// tests in `FavoriteRemoteSyncTests.swift` already cover that).
    func testStartForwardsMangaDirectoryStoreAndSettingsStoreIntoRealEngineAndSurfacesAttributionWarning() async throws {
        defer { FavoriteSyncWiringTestURLProtocol.reset() }
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-sync-wiring")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let libraryStore = FavoriteLibraryStore(defaults: defaults, key: "local-favorites")
        let runStore = FavoriteSyncRunStore(defaults: defaults, key: "sync-runs")

        var document = try await libraryStore.load()
        // Kept out of the sync's target category on purpose so it never
        // becomes an upload candidate in phase 4 — this test only needs to
        // drive the import-phase attribution check, not the upload/formHash
        // network path too.
        let existingSibling = try FavoriteItem(
            target: FavoriteItemTarget(kind: .mangaThread, threadID: "980"),
            title: "第1话",
            sourceGroup: .forumBoard(id: "46", label: "漫画区46"),
            forumID: "46",
            forumName: "漫画区46",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(existingSibling)
        let targetCategory = document.createCategory(name: "远端")
        try await libraryStore.save(document)

        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        try await mangaDirectoryStore.saveDirectory(MangaDirectory(
            cleanBookName: "会话集成测试漫画",
            strategy: .tag,
            sourceKey: "会话集成测试漫画",
            chapters: [
                MangaChapter(tid: "980", rawTitle: "第1话", chapterNumber: 1),
                MangaChapter(tid: "981", rawTitle: "第2话", chapterNumber: 2),
            ]
        ))

        // fid 46's smart bit is off by `BoardReaderSettings`'s factory
        // default — turning it on here, in the *injected* store, is what
        // makes the warning firing meaningful proof of forwarding rather
        // than a coincidence of the engine's own defaults.
        let settingsStore = SettingsStore(defaults: defaults, key: "settings")
        var settings = await settingsStore.load()
        settings.boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
        try await settingsStore.save(settings)

        FavoriteSyncWiringTestURLProtocol.newChapterTID = "981"
        FavoriteSyncWiringTestURLProtocol.newChapterTitle = "第2话"
        FavoriteSyncWiringTestURLProtocol.remoteFavoriteID = "981"
        FavoriteSyncWiringTestURLProtocol.forumID = "46"
        FavoriteSyncWiringTestURLProtocol.forumName = "漫画区46"

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [FavoriteSyncWiringTestURLProtocol.self]
        let mockedURLSession = URLSession(configuration: urlSessionConfiguration)
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        // The route resolver's own settings store only decides `.manga` vs.
        // `.mangaDirect` (both fold into the same `.mangaThread` favorite
        // target — see `FavoriteRemoteSyncSession.probeResult`), so it
        // deliberately does not need to agree with the engine's
        // `settingsStore` above; kept isolated from real `UserDefaults` only
        // for test hygiene.
        let resolverSettingsStore = SettingsStore(defaults: defaults, key: "resolver-settings")

        let session = FavoriteRemoteSyncSession(
            libraryStore: libraryStore,
            runStore: runStore,
            contentCoverStore: ContentCoverStore(defaults: defaults, key: "content-covers"),
            mangaDirectoryStore: mangaDirectoryStore,
            settingsStore: settingsStore,
            makeFavoriteRepository: { FavoriteRepository(client: YamiboClient(session: mockedURLSession)) },
            makeForumThreadReaderRepository: {
                ForumThreadReaderRepository(client: YamiboClient(session: mockedURLSession), cacheStore: forumCacheStore)
            },
            makeThreadRouteResolver: {
                YamiboThreadRouteResolver(client: YamiboClient(session: mockedURLSession), settingsStore: resolverSettingsStore)
            }
            // No `runnerOverride` — this must run the real `makeEngineRunner()`.
        )
        await session.load()

        _ = await session.start(targetCategoryID: targetCategory.id)
        try await waitForStatus(.completed, in: session)

        XCTAssertNil(session.errorMessage)
        let hasAttributionWarning = session.snapshot?.warnings.contains { warning in
            if case let .importedIntoExistingMangaDirectory(_, cleanBookName) = warning {
                return cleanBookName == "会话集成测试漫画"
            }
            return false
        } ?? false
        XCTAssertTrue(hasAttributionWarning)
        let savedItem = try await libraryStore.load().items.first {
            $0.target == FavoriteItemTarget(kind: .mangaThread, threadID: "981")
        }
        XCTAssertEqual(savedItem?.remoteMapping?.yamiboFavoriteID, "981")
    }

    /// Regression test for the mode-off title path: `FavoriteRemoteSyncSession
    /// .probeResult`'s combined `.manga`/`.mangaDirect` case must use the
    /// post's own title verbatim, never run through `MangaTitleCleaner
    /// .cleanBookName`, regardless of whether the board's Smart Comic Mode is
    /// on or off (both mode states store the raw title identically now — see
    /// that combined case's own doc comment for why). This test pins the
    /// mode-off path specifically (fid 46, off by `BoardReaderSettings`'s
    /// own default, so the resolver classifies this thread as `.mangaDirect`)
    /// — see `testStartKeepsRawTitleVerbatimForMangaModeOnRoute` below for the
    /// mode-on (`.manga`) sibling. The raw title below has a bracketed tag
    /// prefix and a chapter-number suffix — both stripped by `cleanBookName`
    /// — so a regression that reintroduces the cleaner on this path would
    /// make the final assertion fail.
    func testStartKeepsRawTitleVerbatimForMangaDirectRoute() async throws {
        defer { FavoriteSyncWiringTestURLProtocol.reset() }
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-sync-mangaDirect-title")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let libraryStore = FavoriteLibraryStore(defaults: defaults, key: "local-favorites")
        let runStore = FavoriteSyncRunStore(defaults: defaults, key: "sync-runs")

        var document = try await libraryStore.load()
        let targetCategory = document.createCategory(name: "远端")
        try await libraryStore.save(document)

        // fid 46 is off by `BoardReaderSettings`'s own default — left
        // untouched here so the resolver classifies this manga-board thread
        // as `.mangaDirect`, not `.manga`.
        let rawTitle = "【连载】测试漫画 第3话"
        FavoriteSyncWiringTestURLProtocol.newChapterTID = "982"
        FavoriteSyncWiringTestURLProtocol.newChapterTitle = rawTitle
        FavoriteSyncWiringTestURLProtocol.remoteFavoriteID = "982"
        FavoriteSyncWiringTestURLProtocol.forumID = "46"
        FavoriteSyncWiringTestURLProtocol.forumName = "漫画区46"

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [FavoriteSyncWiringTestURLProtocol.self]
        let mockedURLSession = URLSession(configuration: urlSessionConfiguration)
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let resolverSettingsStore = SettingsStore(defaults: defaults, key: "resolver-settings")

        let session = FavoriteRemoteSyncSession(
            libraryStore: libraryStore,
            runStore: runStore,
            contentCoverStore: ContentCoverStore(defaults: defaults, key: "content-covers"),
            makeFavoriteRepository: { FavoriteRepository(client: YamiboClient(session: mockedURLSession)) },
            makeForumThreadReaderRepository: {
                ForumThreadReaderRepository(client: YamiboClient(session: mockedURLSession), cacheStore: forumCacheStore)
            },
            makeThreadRouteResolver: {
                YamiboThreadRouteResolver(client: YamiboClient(session: mockedURLSession), settingsStore: resolverSettingsStore)
            }
            // No `runnerOverride` — this must run the real `makeEngineRunner()`
            // so the genuine `FavoriteRemoteSyncSession.probeResult` (not a
            // test double) is what computes the imported title.
        )
        await session.load()

        _ = await session.start(targetCategoryID: targetCategory.id)
        try await waitForStatus(.completed, in: session)

        XCTAssertNil(session.errorMessage)
        let savedItem = try await libraryStore.load().items.first {
            $0.target == FavoriteItemTarget(kind: .mangaThread, threadID: "982")
        }
        XCTAssertEqual(savedItem?.title, rawTitle)
    }

    /// The actual regression test for the mode-on title bug fixed alongside
    /// `testStartKeepsRawTitleVerbatimForMangaDirectRoute` above:
    /// `FavoriteRemoteSyncSession.probeResult`'s `.manga` case used to run the
    /// post's title through `MangaTitleCleaner.cleanBookName` before storing
    /// it, destroying the ability to tell a manga's individually-synced
    /// chapters apart on the "查看归档收藏" archive detail page. No prior test
    /// covered the `.manga` (mode-on) title-storage behavior at all — this
    /// mirrors the sibling test's structure/fixtures exactly, but with fid
    /// "30" (中文百合漫画区, Smart Comic Mode on by `BoardReaderSettings`'s
    /// own default) so the resolver classifies this manga-board thread as
    /// `.manga`, not `.mangaDirect`. The raw title below has the same
    /// bracketed tag prefix and chapter-number suffix that `cleanBookName`
    /// would strip, so a regression that reintroduces the cleaner on this
    /// path would make the final assertion fail.
    func testStartKeepsRawTitleVerbatimForMangaModeOnRoute() async throws {
        defer { FavoriteSyncWiringTestURLProtocol.reset() }
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-sync-manga-modeon-title")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let libraryStore = FavoriteLibraryStore(defaults: defaults, key: "local-favorites")
        let runStore = FavoriteSyncRunStore(defaults: defaults, key: "sync-runs")

        var document = try await libraryStore.load()
        let targetCategory = document.createCategory(name: "远端")
        try await libraryStore.save(document)

        // fid 30 is on by `BoardReaderSettings`'s own default — left
        // untouched here so the resolver classifies this manga-board thread
        // as `.manga`, not `.mangaDirect`.
        let rawTitle = "【连载】测试漫画 第4话"
        FavoriteSyncWiringTestURLProtocol.newChapterTID = "983"
        FavoriteSyncWiringTestURLProtocol.newChapterTitle = rawTitle
        FavoriteSyncWiringTestURLProtocol.remoteFavoriteID = "983"
        FavoriteSyncWiringTestURLProtocol.forumID = "30"
        FavoriteSyncWiringTestURLProtocol.forumName = "中文百合漫画区"

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [FavoriteSyncWiringTestURLProtocol.self]
        let mockedURLSession = URLSession(configuration: urlSessionConfiguration)
        let forumCacheStore = ForumCacheStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let resolverSettingsStore = SettingsStore(defaults: defaults, key: "resolver-settings")

        let session = FavoriteRemoteSyncSession(
            libraryStore: libraryStore,
            runStore: runStore,
            contentCoverStore: ContentCoverStore(defaults: defaults, key: "content-covers"),
            makeFavoriteRepository: { FavoriteRepository(client: YamiboClient(session: mockedURLSession)) },
            makeForumThreadReaderRepository: {
                ForumThreadReaderRepository(client: YamiboClient(session: mockedURLSession), cacheStore: forumCacheStore)
            },
            makeThreadRouteResolver: {
                YamiboThreadRouteResolver(client: YamiboClient(session: mockedURLSession), settingsStore: resolverSettingsStore)
            }
            // No `runnerOverride` — this must run the real `makeEngineRunner()`
            // so the genuine `FavoriteRemoteSyncSession.probeResult` (not a
            // test double) is what computes the imported title.
        )
        await session.load()

        _ = await session.start(targetCategoryID: targetCategory.id)
        try await waitForStatus(.completed, in: session)

        XCTAssertNil(session.errorMessage)
        let savedItem = try await libraryStore.load().items.first {
            $0.target == FavoriteItemTarget(kind: .mangaThread, threadID: "983")
        }
        XCTAssertEqual(savedItem?.title, rawTitle)
    }

    /// 1 second used to be tight enough that the three tests below driving
    /// the real `makeEngineRunner()` (not `runnerOverride`) — which each
    /// take several genuine async hops (probe, route resolution, cover/
    /// metadata fetch, import, persist) even with the HTTP layer mocked —
    /// flaked on GitHub Actions' shared macOS runners while never once
    /// failing locally: CI's failing-test list varied which 1-2 of the 3
    /// timed out from run to run (all 3 once, 2 of 3 another time), the
    /// signature of a too-tight deadline rather than a deterministic bug.
    /// 5s matches the sibling `waitForOrganizerCondition` helper's own
    /// margin (2s) with room to spare for this pipeline's extra hops.
    private func waitForStatus(
        _ status: FavoriteRemoteSyncTaskStatus,
        in session: FavoriteRemoteSyncSession
    ) async throws {
        do {
            try await waitForMainActorCondition(timeout: .seconds(5), pollInterval: .milliseconds(10)) {
                session.snapshot?.status == status
            }
        } catch is TestWaitTimeoutError {
            XCTFail("Timed out waiting for remote sync status \(status)")
        }
    }

    private func makeMangaDirectoryStore(suiteName: String) throws -> MangaDirectoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("favorite-remote-sync-session-tests", isDirectory: true)
            .appendingPathComponent(suiteName, isDirectory: true)
        let database = try YamiboDatabase.openPool(rootDirectory: root)
        return MangaDirectoryStore(databasePool: database)
    }
}

/// Mocks the small slice of `bbs.yamibo.com` HTTP surface the real
/// `makeEngineRunner()` path touches for this file's wiring test: the
/// favorites list (one remote-only manga chapter) and that chapter's own
/// thread page (fetched twice over — once for route classification, once for
/// source-group/cover metadata — both are the same `mod=viewthread` URL, so
/// one branch answers both).
private final class FavoriteSyncWiringTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var newChapterTID = ""
    nonisolated(unsafe) static var newChapterTitle = ""
    nonisolated(unsafe) static var remoteFavoriteID = ""
    nonisolated(unsafe) static var forumID = ""
    nonisolated(unsafe) static var forumName = ""

    static func reset() {
        newChapterTID = ""
        newChapterTitle = ""
        remoteFavoriteID = ""
        forumID = ""
        forumName = ""
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "bbs.yamibo.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let absoluteString = request.url?.absoluteString ?? ""
        let body: String

        if absoluteString.contains("do=favorite") {
            body = """
            <html><body>
              <div class="findbox mt10 cl">
                <ul>
                  <li class="sclist"><a href="home.php?mod=spacecp&amp;ac=favorite&amp;op=delete&amp;favid=\(Self.remoteFavoriteID)" class="dialog mdel"><i class="dm-error"></i></a><a href="forum.php?mod=viewthread&amp;tid=\(Self.newChapterTID)&amp;mobile=2">\(Self.newChapterTitle)</a></li>
                </ul>
              </div>
            </body></html>
            """
        } else if absoluteString.contains("mod=viewthread"), absoluteString.contains("tid=\(Self.newChapterTID)") {
            body = """
            <html>
            <head><title>\(Self.newChapterTitle) - \(Self.forumName) - 百合会</title></head>
            <body>
              <a href="forum.php?mod=forumdisplay&amp;fid=\(Self.forumID)&amp;mobile=2">\(Self.forumName)</a>
              <div id="post_1">
                <div class="authi">
                  <a class="author" href="home.php?mod=space&amp;uid=88&amp;mobile=2">作者名</a>
                  <em>发表于 2026-6-1 10:00</em>
                </div>
                <div class="message" id="postmessage_1">章节正文</div>
              </div>
            </body>
            </html>
            """
        } else {
            body = "<html><body>not found</body></html>"
        }

        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://bbs.yamibo.com/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor FavoriteRemoteSyncTestRecorder {
    private var categoryIDs: [String] = []

    func record(_ categoryID: String) {
        categoryIDs.append(categoryID)
    }

    func recordedCategoryIDs() -> [String] {
        categoryIDs
    }
}

/// Builds a `FavoriteRemoteSyncSession` backed by isolated per-test stores.
@MainActor
private func makeSyncSession(
    libraryStore: FavoriteLibraryStore? = nil,
    runStore: FavoriteSyncRunStore? = nil,
    runnerOverride: FavoriteRemoteSyncSession.EngineRunner? = nil
) throws -> FavoriteRemoteSyncSession {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "favorite-sync-session-deps")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let sessionStore = SessionStore(defaults: defaults, key: "session")
    let urlSession = YamiboNetworkConfiguration.makeSession()
    let forumCacheStore = ForumCacheStore(
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    )
    @Sendable func makeClient() async -> YamiboClient {
        let sessionState = await sessionStore.load()
        return YamiboClient(
            session: urlSession,
            cookie: sessionState.cookie,
            userAgent: sessionState.userAgent
        )
    }
    return FavoriteRemoteSyncSession(
        libraryStore: libraryStore ?? FavoriteLibraryStore(defaults: defaults, key: "local-favorites"),
        runStore: runStore ?? FavoriteSyncRunStore(defaults: defaults, key: "sync-runs"),
        contentCoverStore: ContentCoverStore(defaults: defaults, key: "content-covers"),
        makeFavoriteRepository: { FavoriteRepository(client: await makeClient()) },
        makeForumThreadReaderRepository: { ForumThreadReaderRepository(client: await makeClient(), cacheStore: forumCacheStore) },
        makeThreadRouteResolver: { YamiboThreadRouteResolver(client: await makeClient()) },
        runnerOverride: runnerOverride
    )
}

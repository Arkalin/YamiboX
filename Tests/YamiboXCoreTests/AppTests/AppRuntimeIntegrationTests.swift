import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Suite("App runtime composition", .timeLimit(.minutes(1)))
@MainActor
struct AppRuntimeIntegrationTests {
    enum Mutation: CaseIterable, Sendable {
        case favorites, settings, progress, cover
    }

    @Test(arguments: Mutation.allCases)
    func realStoreMutationMarksWebDAVDirtyWithoutView(mutation: Mutation) async throws {
        let fixture = try RuntimeIntegrationFixture()
        let context = fixture.context
        try await context.webDAVSyncSettingsStore.save(WebDAVSyncSettings(isAutoSyncEnabled: true))
        fixture.runtime.start()
        defer { fixture.runtime.stop() }

        // No readiness sleep: start registers all four store streams synchronously.
        switch mutation {
        case .favorites:
            try await context.localFavoriteLibraryStore.save(FavoriteLibraryDocument())
        case .settings:
            try await context.settingsStore.update { $0.system.usesDataSaverMode.toggle() }
        case .progress:
            try await context.readingProgressStore.saveNovel(NovelReadingPosition(threadID: "2701", view: 2))
        case .cover:
            _ = try await context.contentCoverStore.setTextCoverForced(true, for: .thread(tid: "2701"))
        }
        try await waitForCondition {
            await context.webDAVSyncSettingsStore.load().localUpdatedAt != nil
        }
        #expect(!(await context.webDAVSyncSettingsStore.load().dirtyDatasetIDs).isEmpty)
    }

    @Test func historyIsNormalizedAtStartupAndOnChangesWithoutView() async throws {
        let fixture = try RuntimeIntegrationFixture()
        let context = fixture.context
        try await context.browsingHistoryWorkflow.recordVisit(BrowsingHistoryVisit(
            threadID: "101", title: "Chapter", forumID: "40", reader: .normal
        ))
        try await context.settingsStore.update {
            $0.boardReader.setEntry(.init(mode: .novel), forumID: "40")
        }
        fixture.runtime.start()
        defer { fixture.runtime.stop() }
        try await waitForCondition {
            (try? await context.browsingHistoryStore.snapshotEntries().first?.target) == .novelThread(threadID: "101")
        }

        try await context.settingsStore.update {
            $0.boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "40")
        }
        try await waitForCondition {
            (try? await context.browsingHistoryStore.snapshotEntries().first?.target) == .mangaThread(threadID: "101")
        }
        let directory = MangaDirectory(
            cleanBookName: "Book", strategy: .links, sourceKey: "101",
            chapters: [MangaChapter(tid: "101", rawTitle: "Chapter", chapterNumber: 1)]
        )
        try await context.mangaDirectoryStore.saveDirectory(directory)
        let target = FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: "Book")
        try await waitForCondition {
            (try? await context.browsingHistoryStore.snapshotEntries().first?.target) == target
        }
    }

    @Test func sessionChangesUpdateUnreadWithoutViewOrExtraForegroundEvent() async throws {
        let fixture = try RuntimeIntegrationFixture()
        let context = fixture.context
        fixture.runtime.start()
        defer { fixture.runtime.stop() }
        #expect(fixture.runtime.transition(to: .active))
        #expect(!fixture.runtime.transition(to: .active))
        try await context.sessionStore.save(SessionState(
            cookie: "\(SessionState.authenticationCookieName)=runtime-test", isLoggedIn: true, accountUID: "1"
        ))
        try await waitForMainActorCondition { context.messageUnreadWorkflow.totalCount == 10 }
        try await context.sessionStore.reset()
        try await waitForMainActorCondition { context.messageUnreadWorkflow.summary == nil }

        #expect(fixture.runtime.transition(to: .background))
        try await context.sessionStore.save(SessionState(
            cookie: "\(SessionState.authenticationCookieName)=runtime-second", isLoggedIn: true, accountUID: "2"
        ))
        #expect(fixture.runtime.transition(to: .active))
        try await waitForMainActorCondition { context.messageUnreadWorkflow.totalCount == 10 }
    }

    @Test func stopAndRestartPropagateToRealWorkflowObservers() async throws {
        let fixture = try RuntimeIntegrationFixture()
        let context = fixture.context
        let exits = RuntimeObserverExits()
        // Wrap the production operations only to observe their completion.
        let runtime = AppRuntimeCoordinator(
            observations: [],
            operations: [
                {
                    await context.browsingHistoryWorkflow.observeChanges()
                    exits.history += 1
                },
                {
                    await context.messageUnreadWorkflow.observeSessionChanges()
                    exits.session += 1
                },
            ],
            actions: .init(
                synchronizeForeground: {},
                refreshUnread: { await context.messageUnreadWorkflow.appDidBecomeActive() },
                invalidateUnread: { context.messageUnreadWorkflow.appDidEnterBackground() },
                synchronizeBackground: {}
            )
        )
        defer { runtime.stop() }
        try await context.browsingHistoryWorkflow.recordVisit(BrowsingHistoryVisit(
            threadID: "101", title: "Chapter", forumID: "40", reader: .normal
        ))
        try await context.settingsStore.update {
            $0.boardReader.setEntry(.init(mode: .novel), forumID: "40")
        }
        try await context.sessionStore.save(SessionState(
            cookie: "\(SessionState.authenticationCookieName)=runtime-test", isLoggedIn: true, accountUID: "1"
        ))
        runtime.start()
        runtime.transition(to: .active)
        try await waitForCondition {
            (try? await context.browsingHistoryStore.snapshotEntries().first?.target) == .novelThread(threadID: "101")
        }
        try await waitForMainActorCondition { context.messageUnreadWorkflow.totalCount == 10 }

        runtime.stop()
        try await waitForMainActorCondition { exits.history == 1 && exits.session == 1 }
        try await context.settingsStore.update {
            $0.boardReader.setEntry(.init(mode: .normal), forumID: "40")
        }
        try await context.sessionStore.reset()
        #expect(try await context.browsingHistoryStore.snapshotEntries().first?.target == .novelThread(threadID: "101"))
        #expect(context.messageUnreadWorkflow.totalCount == 10)

        runtime.start()
        try await waitForCondition {
            (try? await context.browsingHistoryStore.snapshotEntries().first?.target) == .normalThread(threadID: "101")
        }
        try await waitForMainActorCondition { context.messageUnreadWorkflow.summary == nil }
        runtime.stop()
        try await waitForMainActorCondition { exits.history == 2 && exits.session == 2 }
    }
}

@MainActor
private final class RuntimeObserverExits {
    var history = 0
    var session = 0
}

@MainActor
private final class RuntimeIntegrationFixture {
    let context: YamiboAppContext
    let runtime: AppRuntimeCoordinator
    private let root: URL
    private let defaults: UserDefaults
    private let suiteName: String
    private let session: URLSession

    init() throws {
        suiteName = "AppRuntimeIntegration-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        let database = try YamiboDatabase.openPool(rootDirectory: root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeUnreadURLProtocol.self]
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: defaults),
            profileStore: YamiboProfileStore(defaults: defaults),
            checkInStore: YamiboCheckInStore(defaults: defaults),
            settingsStore: SettingsStore(defaults: defaults),
            webDAVSyncSettingsStore: WebDAVSyncSettingsStore(defaults: defaults),
            readerResumeRouteStore: ReaderResumeRouteStore(defaults: defaults),
            localFavoriteLibraryStore: FavoriteLibraryStore(defaults: defaults, databasePool: database),
            readingProgressStore: ReadingProgressStore(defaults: defaults, databasePool: database),
            databasePool: database,
            grdbRootDirectory: root,
            cachesRootDirectory: root.appendingPathComponent("caches", isDirectory: true),
            uiDefaults: defaults,
            session: session
        )
        runtime = context.makeRuntimeCoordinator(continuity: AppContinuityWorkflow(appContext: context))
    }

    isolated deinit {
        runtime.stop()
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RuntimeUnreadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let html = """
        <div class="dhnv">
          <a href="home.php?mod=space&amp;do=pm">PM<strong>(4)</strong></a>
          <a href="home.php?mod=space&amp;do=notice">Notice<strong>(6)</strong></a>
        </div>
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

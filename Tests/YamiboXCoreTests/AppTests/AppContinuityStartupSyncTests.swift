import Foundation
import GRDB
import Testing
@testable import YamiboXCore

@Suite struct AppContinuityStartupSyncTests {
    @Test(arguments: StartupReaderKind.allCases, StartupMergeOutcome.allCases)
    func mergedProgressSurvivesStartupAndSubsequentSaves(
        kind: StartupReaderKind, outcome: StartupMergeOutcome
    ) async throws {
        let fixture = try StartupSyncFixture(kind: kind)
        defer { fixture.cleanUp() }
        try await fixture.prepare(progressDirty: outcome != .settingsUpload, settingsDirty: outcome == .settingsUpload)
        try fixture.seedProgress([fixture.record(position: 20, date: fixture.remoteDate)])
        if outcome == .conflictsExhausted { fixture.server.conflictNextWrites(10) }
        if outcome == .putFailure {
            fixture.handleRequests { request in
                if request.httpMethod == "PUT", request.url?.lastPathComponent == StartupSyncFixture.progressFile {
                    throw URLError(.networkConnectionLost)
                }
            }
        }

        let result = await fixture.workflow.launchIfNeeded(canRestoreReaderRoute: true)

        let restored = try #require(result.restoredRoute)
        #expect(kind.position(in: restored) == 20)
        #expect(await fixture.routeStore.load() == restored)
        #expect(await fixture.localPosition() == 20)
        let settings = await fixture.syncSettings.load()
        #expect(settings.dirtyDatasetIDs.contains("readingProgress") == outcome.failsUpload)
        if !outcome.failsUpload {
            let uploadedID = outcome == .settingsUpload ? "appSettings" : "readingProgress"
            #expect(settings.localRevisionByDatasetID[uploadedID] != nil)
        }

        fixture.server.conflictNextWrites(0)
        fixture.handleRequests()
        let sync = ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(readingProgressStore: fixture.progress),
            debounceNanoseconds: 60_000_000_000
        )
        let position = kind.position(from: restored)
        await sync.queue(position)
        try await sync.flush(position)
        try await sync.flush(position)
        try await fixture.context.makeWebDAVSyncService().synchronizeAutomatically(bypassingMinimumInterval: true)
        #expect(await fixture.localPosition() == 20)
        #expect(try fixture.remotePosition() == 20)
        #expect(await fixture.syncSettings.load().dirtyDatasetIDs.isEmpty)
    }

    @Test(arguments: StartupReaderKind.allCases, [false, true])
    func downloadsAndFirstRemoteProgressCorrectTheRoute(kind: StartupReaderKind, initiallyMissing: Bool) async throws {
        let fixture = try StartupSyncFixture(kind: kind)
        defer { fixture.cleanUp() }
        try await fixture.prepare(initiallyMissing: initiallyMissing)
        try fixture.seedProgress([fixture.record(position: 20, date: fixture.remoteDate)])

        let result = await fixture.workflow.launchIfNeeded(canRestoreReaderRoute: true)

        #expect(kind.position(in: result.restoredRoute) == 20)
        #expect(await fixture.routeStore.load() == result.restoredRoute)
        #expect(await fixture.localPosition() == 20)
        #expect(fixture.server.payloadWriteCount == 0)
    }

    @Test(arguments: StartupReaderKind.allCases, StartupUnchangedScenario.allCases)
    func unrelatedOrUnchangedSyncPreservesLocalRoute(
        kind: StartupReaderKind, scenario: StartupUnchangedScenario
    ) async throws {
        let fixture = try StartupSyncFixture(kind: kind)
        defer { fixture.cleanUp() }
        // The route may be ahead of the debounced progress store.
        try await fixture.prepare(progressDirty: scenario == .progressUpload, settingsDirty: scenario == .settingsUpload)
        let localRoute = kind.route(position: 7)
        try await fixture.routeStore.save(localRoute)
        switch scenario {
        case .progressUpload, .settingsUpload:
            break
        case .noChange:
            try fixture.seedProgress([fixture.record(position: 3, date: fixture.localDate)], revision: 1)
        case .otherBook:
            try fixture.seedProgress([
                fixture.record(position: 3, date: fixture.localDate),
                fixture.record(position: 20, date: fixture.remoteDate, threadID: "other")
            ])
        case .fetchFailure:
            fixture.handleRequests { request in
                if request.httpMethod == "GET" { throw URLError(.notConnectedToInternet) }
            }
        }

        let result = await fixture.workflow.launchIfNeeded(canRestoreReaderRoute: true)

        #expect(result.restoredRoute == localRoute)
        #expect(await fixture.routeStore.load() == localRoute)
        #expect(await fixture.localPosition() == 3)
        if scenario == .otherBook {
            #expect(await fixture.progress.loadAll().count == 2)
        }
    }

    @Test(arguments: StartupReaderKind.allCases)
    func reconciliationRereadsProgressAfterObservation(kind: StartupReaderKind) async throws {
        let fixture = try StartupSyncFixture(kind: kind)
        defer { fixture.cleanUp() }
        try await fixture.prepare()
        try fixture.seedProgress([fixture.record(position: 20, date: fixture.remoteDate)])

        let result = await fixture.workflow.launchIfNeeded(canRestoreReaderRoute: true) { phase in
            if phase == .loadingReadingPosition {
                do { try await fixture.progress.replaceAll([fixture.record(position: 25, date: .now)]) }
                catch { Issue.record(error) }
            }
        }

        #expect(kind.position(in: result.restoredRoute) == 25)
        #expect(await fixture.localPosition() == 25)
    }

    @Test(arguments: StartupReadFailure.allCases, [false, true])
    func observationReadFailuresFallBackToSyncDirection(
        failure: StartupReadFailure, uploadsSettings: Bool
    ) async throws {
        let fixture = try StartupSyncFixture(kind: .mangaTitle)
        defer { fixture.cleanUp() }
        try await fixture.prepare(settingsDirty: uploadsSettings)
        try await fixture.progress.replaceAll([fixture.record(position: 20, date: fixture.remoteDate)])
        try await fixture.syncSettings.update { settings in
            settings.disabledContentIDs.insert("readingProgress")
        }
        try fixture.seedAppSettings()
        if failure != .after { try await fixture.hideProgressTable() }
        let pool = fixture.database.pool
        fixture.handleRequests { request in
            guard request.httpMethod == "GET", request.url?.lastPathComponent == StartupSyncFixture.settingsFile else { return }
            switch failure {
            case .before:
                try pool.write { db in try db.execute(sql: "ALTER TABLE hidden_progress RENAME TO reading_progress") }
            case .after:
                try pool.write { db in try db.execute(sql: "ALTER TABLE reading_progress RENAME TO hidden_progress") }
            case .both:
                break
            }
        }

        let result = await fixture.workflow.launchIfNeeded(canRestoreReaderRoute: true) { phase in
            if phase == .loadingReadingPosition, failure != .before {
                do { try await fixture.revealProgressTable() }
                catch { Issue.record(error) }
            }
        }

        #expect(StartupReaderKind.mangaTitle.position(in: result.restoredRoute) == (uploadsSettings ? 3 : 20))
        #expect(await fixture.localPosition() == 20)
        #expect((await fixture.syncSettings.load().localRevisionByDatasetID["appSettings"] != nil) == uploadsSettings)
    }

    @Test(arguments: [false, true])
    func throwingQueriesDistinguishMissingRecordsFromReadFailures(exactTarget: Bool) async throws {
        let fixture = try StartupSyncFixture(kind: .mangaThread)
        defer { fixture.cleanUp() }
        if exactTarget {
            #expect(try await fixture.progress.loadThrowing(for: .mangaThread(threadID: "chapter")) == nil)
        } else {
            #expect(try await fixture.progress.loadThrowing(threadID: "chapter") == nil)
        }
        try await fixture.hideProgressTable()
        if exactTarget {
            await #expect(throws: DatabaseError.self) {
                _ = try await fixture.progress.loadThrowing(for: .mangaThread(threadID: "chapter"))
            }
            #expect(await fixture.progress.load(for: .mangaThread(threadID: "chapter")) == nil)
        } else {
            await #expect(throws: DatabaseError.self) {
                _ = try await fixture.progress.loadThrowing(threadID: "chapter")
            }
            #expect(await fixture.progress.load(threadID: "chapter") == nil)
        }
    }

    @Test(arguments: StartupRouteChange.allCases, [false, true])
    func navigationInvalidatesStartupObservation(change: StartupRouteChange, duringRestore: Bool) async throws {
        let fixture = try StartupSyncFixture(kind: .mangaTitle)
        defer { fixture.cleanUp() }
        try await fixture.prepare()
        try fixture.seedProgress([fixture.record(position: 20, date: fixture.remoteDate)])
        let replacement = change == .presentSameRoute
            ? StartupReaderKind.mangaTitle.route(position: 3)
            : StartupReaderKind.mangaTitle.route(position: 8, threadID: "other")
        let workflow = fixture.workflow
        let routeStore = fixture.routeStore
        let changeRoute: @Sendable () throws -> Void = {
            switch change {
            case .dismiss: workflow.readerRouteDismissed()
            case .present, .presentSameRoute: workflow.readerRoutePresented(replacement)
            case .replacePersistedRoute: try routeStore.saveSync(replacement)
            }
        }
        if !duringRestore {
            fixture.handleRequests { request in
                if request.httpMethod == "GET", request.url?.lastPathComponent == StartupSyncFixture.progressFile {
                    try changeRoute()
                }
            }
        }

        let result = await workflow.launchIfNeeded(canRestoreReaderRoute: true) { phase in
            if duringRestore, phase == .loadingReadingPosition {
                do { try changeRoute() } catch { Issue.record(error) }
            }
        }

        #expect(result.restoredRoute == nil)
        #expect(await fixture.routeStore.load() == (change == .dismiss ? nil : replacement))
    }

    @Test(arguments: [false, true])
    func accountChangeInvalidatesStartupObservation(duringRestore: Bool) async throws {
        let fixture = try StartupSyncFixture(kind: .mangaTitle)
        defer { fixture.cleanUp() }
        try await fixture.prepare()
        try fixture.seedProgress([fixture.record(position: 20, date: fixture.remoteDate)])
        let original = await fixture.routeStore.load()

        let result = await fixture.workflow.launchIfNeeded(canRestoreReaderRoute: true) { phase in
            if phase == (duringRestore ? .loadingReadingPosition : .synchronizingWebDAV) {
                do {
                    try await fixture.context.sessionStore.save(SessionState(
                        cookie: "\(SessionState.authenticationCookieName)=other", isLoggedIn: true, accountUID: "2"
                    ))
                } catch { Issue.record(error) }
            }
        }

        #expect(result.restoredRoute == nil)
        #expect(await fixture.routeStore.load() == original)
    }

    @Test(arguments: [false, true])
    func startupWithoutARestorableRouteStillSynchronizes(hasSavedRoute: Bool) async throws {
        let fixture = try StartupSyncFixture(kind: .mangaTitle)
        defer { fixture.cleanUp() }
        try await fixture.prepare()
        if !hasSavedRoute { await fixture.routeStore.clear() }
        let original = await fixture.routeStore.load()
        try fixture.seedProgress([fixture.record(position: 20, date: fixture.remoteDate)])

        let result = await fixture.workflow.launchIfNeeded(canRestoreReaderRoute: !hasSavedRoute)

        #expect(result.restoredRoute == nil)
        #expect(await fixture.routeStore.load() == original)
        #expect(await fixture.localPosition() == 20)
    }

    @Test(arguments: [0, 3])
    func absentProgressRetainsExistingRouteFallback(initialPage: Int) async throws {
        let fixture = try StartupSyncFixture(kind: .mangaTitle)
        defer { fixture.cleanUp() }
        try await fixture.prepare(initiallyMissing: true)
        let route = StartupReaderKind.mangaTitle.route(position: initialPage)
        try await fixture.routeStore.save(route)
        try fixture.seedProgress([])

        let result = await fixture.workflow.launchIfNeeded(canRestoreReaderRoute: true)

        #expect(result.restoredRoute == (initialPage == 0 ? nil : route))
        #expect(await fixture.routeStore.load() == result.restoredRoute)
    }
}

enum StartupReaderKind: CaseIterable, Sendable {
    case novel, mangaTitle, mangaThread

    func route(position: Int, threadID: String = "chapter") -> ReaderResumeRoute {
        if self == .novel {
            return .novel(NovelLaunchContext(threadID: threadID, threadTitle: "Book", source: .resume, initialView: position, forumID: "30"))
        }
        return .manga(MangaLaunchContext(
            originalThreadID: threadID, chapterTID: threadID, displayTitle: "Book", source: .resume,
            initialPage: position, directoryName: "Book", isSmartModeEnabled: self == .mangaTitle, forumID: "30"
        ))
    }

    func position(in route: ReaderResumeRoute?) -> Int? {
        switch route {
        case let .novel(context): context.initialView
        case let .manga(context): context.initialPage
        case nil: nil
        }
    }

    func position(from route: ReaderResumeRoute) -> ProgressSyncPosition {
        switch route {
        case let .novel(context):
            .novel(NovelReadingPosition(threadID: context.threadID, view: context.initialView ?? 1, chapterTitle: "Chapter"))
        case let .manga(context):
            .manga(MangaProgressReadingPosition(
                threadID: context.originalThreadID, chapterThreadID: context.chapterTID, chapterTitle: "Chapter",
                pageIndex: context.initialPage, pageCount: 40, mangaID: "book", directoryName: "Book",
                isSmartModeEnabled: self == .mangaTitle
            ))
        }
    }
}

enum StartupMergeOutcome: CaseIterable, Sendable {
    case progressUpload, settingsUpload, putFailure, conflictsExhausted
    var failsUpload: Bool { self == .putFailure || self == .conflictsExhausted }
}

enum StartupUnchangedScenario: CaseIterable, Sendable {
    case progressUpload, settingsUpload, noChange, otherBook, fetchFailure
}

enum StartupReadFailure: CaseIterable, Sendable { case before, after, both }
enum StartupRouteChange: CaseIterable, Sendable { case dismiss, present, presentSameRoute, replacePersistedRoute }

private final class StartupSyncFixture: Sendable {
    static let progressFile = "yamibox-reading-progress-v1.json"
    static let settingsFile = "yamibox-app-settings-v1.json"
    let database: DeletionTestDatabase
    let progress: ReadingProgressStore
    let routeStore: ReaderResumeRouteStore
    let syncSettings: WebDAVSyncSettingsStore
    let context: YamiboAppContext
    let workflow: AppContinuityWorkflow
    let server = WebDAVMemoryServer()
    let suite = "startup-sync-\(UUID().uuidString)"
    let host = "\(UUID().uuidString.lowercased()).example.com"
    let kind: StartupReaderKind
    let localDate = Date(timeIntervalSince1970: 1_000)
    let remoteDate = Date(timeIntervalSince1970: 2_000)

    init(kind: StartupReaderKind) throws {
        self.kind = kind
        database = try DeletionTestDatabase()
        let defaults = try #require(UserDefaults(suiteName: suite))
        progress = ReadingProgressStore(databasePool: database.pool)
        routeStore = ReaderResumeRouteStore(defaults: defaults)
        syncSettings = WebDAVSyncSettingsStore(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        context = YamiboAppContext(
            sessionStore: SessionStore(defaults: defaults), settingsStore: SettingsStore(defaults: defaults),
            webDAVSyncSettingsStore: syncSettings, readerResumeRouteStore: routeStore, readingProgressStore: progress,
            databasePool: database.pool, grdbRootDirectory: database.root,
            cachesRootDirectory: database.root.appendingPathComponent("caches"),
            uiDefaults: defaults, clearsWebDataOnReset: false, session: session, imageSession: session
        )
        workflow = AppContinuityWorkflow(appContext: context)
        handleRequests()
    }

    func prepare(progressDirty: Bool = false, settingsDirty: Bool = false, initiallyMissing: Bool = false) async throws {
        try await context.sessionStore.save(SessionState(
            cookie: "\(SessionState.authenticationCookieName)=test", isLoggedIn: true, accountUID: "1"
        ))
        try await routeStore.save(kind.route(position: 3))
        if !initiallyMissing { try await progress.replaceAll([record(position: 3, date: localDate)]) }
        var settings = WebDAVSyncSettings(
            baseURLString: "https://\(host)", username: "test", password: "test", isAutoSyncEnabled: true
        )
        settings.disabledContentIDs = Set(WebDAVSyncContent.allCases.map(\.rawValue)).subtracting(["readingProgress", "appSettings"])
        settings.lastAppliedRemoteRevisionByDatasetID = ["readingProgress": 1, "appSettings": 1]
        settings.localUpdatedAt = localDate
        settings.lastSyncedFingerprintByDatasetID["readingProgress"] = try await ReadingProgressWebDAVParticipant(store: progress).readLocalFingerprint()
        settings.lastSyncedFingerprintByDatasetID["appSettings"] = try await AppSettingsWebDAVParticipant(store: context.settingsStore).readLocalFingerprint()
        if progressDirty { settings.dirtyDatasetIDs.insert("readingProgress") }
        if settingsDirty { settings.dirtyDatasetIDs.insert("appSettings") }
        try await syncSettings.save(settings)
    }

    func record(position: Int, date: Date, threadID: String = "chapter") -> ReadingProgressRecord {
        let target: FavoriteContentTarget
        switch kind {
        case .novel: target = .novelThread(threadID: threadID)
        case .mangaThread: target = .mangaThread(threadID: threadID)
        case .mangaTitle: target = FavoriteContentTarget(mangaID: threadID == "chapter" ? "book" : "other-book", mangaCleanBookName: "Book")
        }
        return ReadingProgressRecord(
            contentTarget: target, threadID: threadID, kind: kind == .novel ? .novel : .manga,
            updatedAt: date, lastReadAt: date,
            novel: kind == .novel ? NovelReadingProgressRecord(lastView: position, lastChapter: "Chapter") : nil,
            manga: kind == .novel ? nil : MangaReadingProgressRecord(
                chapterThreadID: threadID, lastChapter: "Chapter", mangaPageIndex: position, mangaPageCount: 40
            )
        )
    }

    func seedProgress(_ records: [ReadingProgressRecord], revision: UInt64 = 2) throws {
        server.seed(Self.progressFile, data: try JSONEncoder().encode(ReadingProgressWebDAVPayload(
            updatedAt: remoteDate, syncRevision: revision, records: records
        )))
    }

    func seedAppSettings() throws {
        server.seed(Self.settingsFile, data: try JSONEncoder().encode(AppSettingsWebDAVPayload(
            updatedAt: remoteDate, syncRevision: 2,
            appSettings: WebDAVSyncedAppSettings(settings: AppSettings())
        )))
    }

    func localPosition() async -> Int? {
        let record = await progress.load(for: record(position: 0, date: localDate).contentTarget!)
        return kind == .novel ? record?.novel?.lastView : record?.manga?.mangaPageIndex
    }

    func remotePosition() throws -> Int? {
        let payload = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: #require(server.data(Self.progressFile)))
        let record = payload.records.first { $0.threadID == "chapter" }
        return kind == .novel ? record?.novel?.lastView : record?.manga?.mangaPageIndex
    }

    func handleRequests(_ beforeResponse: @escaping @Sendable (URLRequest) throws -> Void = { _ in }) {
        WebDAVTestURLProtocol.setHandler(for: host, emulatesConditionalSupport: false) { [server] request in
            try beforeResponse(request)
            return try server.respond(request)
        }
    }

    func hideProgressTable() async throws {
        try await database.pool.write { db in try db.execute(sql: "ALTER TABLE reading_progress RENAME TO hidden_progress") }
    }

    func revealProgressTable() async throws {
        try await database.pool.write { db in try db.execute(sql: "ALTER TABLE hidden_progress RENAME TO reading_progress") }
    }

    func cleanUp() {
        WebDAVTestURLProtocol.removeHandler(for: host)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

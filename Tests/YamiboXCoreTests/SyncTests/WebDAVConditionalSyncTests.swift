import Foundation
import Testing
@testable import YamiboXCore

@Suite struct WebDAVConditionalSyncTests {
    private let name = "yamibox-reading-progress-v1.json"

    @Test(arguments: [false, true])
    func unsafeServerNeverReceivesUserPayload(omitsETags: Bool) async throws {
        let server = WebDAVMemoryServer(omitsETags: omitsETags, ignoresConditions: !omitsETags)
        let fixture = try ConditionalSyncFixture(server: server)
        try await fixture.prepare()
        try await fixture.progress.clearAllForSync()
        await #expect(throws: WebDAVSyncError.unsafeConditionalWrite) {
            _ = try await fixture.service().upload()
        }
        #expect(server.payloadWriteCount == 0)
        #expect(server.probeFileCount == 0)
        #expect(await fixture.settingsStore.load().dirtyDatasetIDs.contains("readingProgress"))
    }

    @Test func conflictRetriesMergeTheCompetingDeletion() async throws {
        let fixture = try ConditionalSyncFixture()
        try await fixture.prepare()
        let old = Date(timeIntervalSince1970: 1_000)
        let cleared = Date(timeIntervalSince1970: 2_000)
        try await fixture.progress.saveNormalThread(threadID: "old", page: 5, date: old)
        let remote = ReadingProgressWebDAVPayload(updatedAt: cleared, syncRevision: 10, records: [],
            deletions: SyncDeletionState(clearedAt: cleared))
        fixture.server.conflictNextWrites(1, replacingWith: try JSONEncoder().encode(remote))
        _ = try await fixture.service().upload()
        #expect(fixture.server.payloadWriteCount == 2)
        #expect(fixture.server.probeFileCount == 0)
        #expect(await fixture.progress.loadAll().isEmpty)
        let uploaded = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self,
            from: #require(fixture.server.data(name)))
        #expect(uploaded.deletions.clearedAt == cleared)
        #expect(uploaded.syncRevision == 11)
        #expect(await fixture.settingsStore.load().dirtyDatasetIDs.isEmpty)
    }

    @Test func exhaustedConflictsKeepLocalDeletionPending() async throws {
        let fixture = try ConditionalSyncFixture()
        try await fixture.prepare()
        try await fixture.progress.clearAllForSync()
        fixture.server.conflictNextWrites(10)
        await #expect(throws: WebDAVSyncError.writeConflict) { _ = try await fixture.service().upload() }
        #expect(fixture.server.payloadWriteCount == 4)
        #expect(fixture.server.data(name) == nil)
        #expect(await fixture.settingsStore.load().dirtyDatasetIDs.contains("readingProgress"))
        #expect(try await fixture.progress.syncSnapshot().deletions.clearedAt != nil)
    }

    @Test(arguments: ["{bad-json", #"{"version":99,"updatedAt":0,"records":[]}"#])
    func malformedRemoteNeverBecomesAnEmptyDataset(json: String) async throws {
        let fixture = try ConditionalSyncFixture()
        try await fixture.prepare()
        let data = Data(json.utf8)
        fixture.server.seed(name, data: data)
        await #expect(throws: (any Error).self) { _ = try await fixture.service().upload() }
        #expect(fixture.server.payloadWriteCount == 0)
        #expect(fixture.server.data(name) == data)
    }

    @Test func manualDownloadPreservesDeletionWithoutUploading() async throws {
        let fixture = try ConditionalSyncFixture()
        try await fixture.prepare()
        let item = try await fixture.progress.saveNormalThread(threadID: "old", page: 2, date: Date(timeIntervalSince1970: 1_000))
        fixture.server.seed(name, data: try JSONEncoder().encode(ReadingProgressWebDAVPayload(
            updatedAt: Date(timeIntervalSince1970: 1_000), records: [item])))
        try await fixture.progress.clearAllForSync(at: Date(timeIntervalSince1970: 2_000))
        _ = try await fixture.service().download()
        #expect(await fixture.progress.loadAll().isEmpty)
        #expect(fixture.server.payloadWriteCount == 0)
        #expect(await fixture.settingsStore.load().dirtyDatasetIDs.contains("readingProgress"))
        _ = try await fixture.service().synchronizeAutomatically(bypassingMinimumInterval: true)
        #expect(try JSONDecoder().decode(ReadingProgressWebDAVPayload.self,
            from: #require(fixture.server.data(name))).records.isEmpty)
        #expect(await fixture.settingsStore.load().dirtyDatasetIDs.isEmpty)
    }

    @Test func firstCreationUsesAnAbsentPrecondition() async throws {
        let fixture = try ConditionalSyncFixture()
        try await fixture.prepare()
        _ = try await fixture.service().upload()
        let client = fixture.client()
        await #expect(throws: WebDAVSyncError.writeConflict) {
            try await client.uploadPayloadData(Data("{}".utf8), settings: fixture.settings,
                fileName: name, condition: .absent)
        }
        #expect(try JSONDecoder().decode(ReadingProgressWebDAVPayload.self,
            from: #require(fixture.server.data(name))).version == 3)
    }

    @Test(arguments: [false, true])
    func changesAfterExportRemainPending(clearsProgress: Bool) async throws {
        let fixture = try ConditionalSyncFixture()
        try await fixture.prepare()
        try await fixture.progress.saveNormalThread(threadID: "old", page: 1,
            date: Date(timeIntervalSince1970: 1_000))
        let exported = SyncTestGate()
        let resume = SyncTestGate()
        let participant = PausedProgressExport(base: ReadingProgressWebDAVParticipant(store: fixture.progress),
            exported: exported, resume: resume)
        let service = WebDAVSyncService(settingsStore: fixture.settingsStore, sessionStore: fixture.sessionStore,
            participants: [participant], client: fixture.client())
        let upload = Task { try await service.upload() }
        await exported.wait()
        if clearsProgress {
            try await fixture.progress.clearAllForSync(at: Date(timeIntervalSince1970: 2_000))
        } else {
            try await fixture.progress.saveNormalThread(threadID: "new", page: 3,
                date: Date(timeIntervalSince1970: 2_000))
        }
        await resume.open()
        _ = try await upload.value
        let pending = await fixture.settingsStore.load()
        #expect(pending.dirtyDatasetIDs.contains("readingProgress"))
        #expect(pending.lastSyncedFingerprintByDatasetID["readingProgress"] != (try await participant.readLocalFingerprint()))
        let stale = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self,
            from: #require(fixture.server.data(name)))
        #expect(stale.records.count == 1)
        _ = try await fixture.service().synchronizeAutomatically(bypassingMinimumInterval: true)
        let synchronized = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self,
            from: #require(fixture.server.data(name)))
        #expect(synchronized.records.count == (clearsProgress ? 0 : 2))
        #expect(await fixture.settingsStore.load().dirtyDatasetIDs.isEmpty)
    }

    @Test func coordinatorSerializesOperationsAcrossSuspensions() async throws {
        let coordinator = WebDAVSyncCoordinator()
        let gate = SyncTestGate()
        let events = SyncTestEvents()
        let first = Task {
            try await coordinator.run {
                await events.append("first-start")
                await gate.wait()
                await events.append("first-end")
            }
        }
        await events.waitForCount(1)
        let second = Task {
            try await coordinator.run { await events.append("second") }
        }
        await gate.open()
        try await first.value
        try await second.value
        #expect(await events.values == ["first-start", "first-end", "second"])
    }

    @Test func resetCancelsAndDrainsLateResponsesBeforeErasing() async throws {
        let coordinator = WebDAVSyncCoordinator()
        let started = SyncTestGate()
        let state = SyncTestEvents()
        let operation = Task {
            try await coordinator.run {
                await started.open()
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    // A dependency may ignore cancellation and still complete
                    // its write. Reset must wait for even this late work.
                    await state.append("late-response")
                }
            }
        }
        await started.wait()
        try await coordinator.reset { await state.append("reset") }
        _ = try? await operation.value
        #expect(await state.values == ["late-response", "reset"])
        try await coordinator.run { await state.append("new-session") }
        #expect(await state.values.last == "new-session")
    }
}

private struct PausedProgressExport: WebDAVSyncParticipant {
    let base: ReadingProgressWebDAVParticipant
    let exported: SyncTestGate
    let resume: SyncTestGate
    var datasetID: String { base.datasetID }
    var remoteFileName: String { base.remoteFileName }
    var uploadsOnlyWhenMarkedDirty: Bool { true }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo { try base.inspectRemote(data) }
    func readLocalFingerprint() async throws -> String? { try await base.readLocalFingerprint() }
    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot { try await base.applyRemoteSnapshot(data) }
    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> WebDAVExportSnapshot {
        let snapshot = try await base.mergeAndExportSnapshot(remoteData: remoteData, updatedAt: updatedAt, accountUID: accountUID)
        await exported.open()
        await resume.wait()
        return snapshot
    }
}

private final class ConditionalSyncFixture: Sendable {
    let database: DeletionTestDatabase
    let progress: ReadingProgressStore
    let settingsStore: WebDAVSyncSettingsStore
    let sessionStore: SessionStore
    let settings: WebDAVSyncSettings
    let server: WebDAVMemoryServer
    let suite: String
    let host: String

    init(server: WebDAVMemoryServer = WebDAVMemoryServer()) throws {
        self.server = server
        suite = "conditional-sync-\(UUID().uuidString)"
        host = "\(UUID().uuidString.lowercased()).example.com"
        database = try DeletionTestDatabase()
        progress = ReadingProgressStore(databasePool: database.pool)
        settingsStore = WebDAVSyncSettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        sessionStore = SessionStore(defaults: try #require(UserDefaults(suiteName: suite)))
        settings = WebDAVSyncSettings(baseURLString: "https://\(host)", username: "test", password: "test", isAutoSyncEnabled: true)
        WebDAVTestURLProtocol.setHandler(for: host, emulatesConditionalSupport: false) { request in
            try server.respond(request)
        }
    }

    func prepare() async throws {
        try await settingsStore.save(settings)
        try await sessionStore.save(SessionState(cookie: "sid=test", isLoggedIn: true, accountUID: "1"))
    }

    func client() -> WebDAVClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WebDAVTestURLProtocol.self]
        return WebDAVClient(session: URLSession(configuration: config))
    }

    func service() -> WebDAVSyncService {
        WebDAVSyncService(settingsStore: settingsStore, sessionStore: sessionStore,
            participants: [ReadingProgressWebDAVParticipant(store: progress)], client: client())
    }

    deinit {
        WebDAVTestURLProtocol.removeHandler(for: host)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

private actor SyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor SyncTestEvents {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func waitForCount(_ count: Int) async {
        while values.count < count { await Task.yield() }
    }
}

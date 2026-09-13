import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Suite struct WebDAVContentSelectionTests {
    @Test func oldSettingsKeepCredentialsAndEnableAllContent() throws {
        let settings = try JSONDecoder().decode(WebDAVSyncSettings.self, from: Data(#"{"baseURLString":"https://example.com","username":"user","password":"secret"}"#.utf8))
        #expect(WebDAVSyncContent.allCases.count == 8)
        #expect(WebDAVSyncContent.allCases.allSatisfy(settings.isEnabled))
        #expect(settings.username == "user")
        #expect(settings.password == "secret")
        #expect(try JSONDecoder().decode(WebDAVSyncSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func selectionUpdatesPreserveMetadataAndInvalidateReenabledContent() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        var settings = await fixture.settings.load()
        settings.lastSyncedFingerprintByDatasetID["browsingHistory"] = "old"
        settings.lastAppliedRemoteRevisionByDatasetID["browsingHistory"] = 5
        settings.localRevisionByDatasetID["browsingHistory"] = 6
        settings.lastSyncedAt = Date(timeIntervalSince1970: 100)
        try await fixture.settings.save(settings)
        try await fixture.settings.setContent(.browsingHistory, enabled: false)
        let disabled = await fixture.settings.load()
        #expect(disabled.lastSyncedAt == settings.lastSyncedAt)
        #expect(!disabled.isEnabled(.browsingHistory))
        try await fixture.settings.setContent(.browsingHistory, enabled: true)
        let enabled = await fixture.settings.load()
        #expect(enabled.dirtyDatasetIDs.contains("browsingHistory"))
        #expect(enabled.lastSyncedFingerprintByDatasetID["browsingHistory"] == nil)
        #expect(enabled.lastAppliedRemoteRevisionByDatasetID["browsingHistory"] == nil)
        #expect(enabled.localRevisionByDatasetID["browsingHistory"] == 6)
    }

    @Test(arguments: WebDAVSyncContent.allCases)
    func disabledContentIsNeverFetchedOrUploaded(content: WebDAVSyncContent) async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try await fixture.settings.setContent(content, enabled: false)
        let server = WebDAVMemoryServer()
        let forbiddenFile = "\(content.rawValue).json"
        WebDAVTestURLProtocol.setHandler(for: fixture.host, emulatesConditionalSupport: false) { request in
            #expect(request.url?.lastPathComponent != forbiddenFile)
            return try server.respond(request)
        }
        defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }
        let participants = WebDAVSyncContent.allCases.map { SelectionTestParticipant(datasetID: $0.rawValue) }
        let service = fixture.service(participants: participants)
        try await service.upload()
        try await service.download()
        _ = try await service.synchronizeAutomatically(bypassingMinimumInterval: true)
        #expect(server.data(forbiddenFile) == nil)
    }

    @Test func allDisabledSkipsNetworkAndDoesNotAdvanceTimestamps() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        for content in WebDAVSyncContent.allCases { try await fixture.settings.setContent(content, enabled: false) }
        let before = await fixture.settings.load()
        try await fixture.service().markLocalDataChanged()
        #expect(try await fixture.service().synchronizeAutomatically() == .skipped)
        await #expect(throws: WebDAVSyncError.noContentSelected) { try await fixture.service().upload() }
        #expect(await fixture.settings.load() == before)
    }

    @Test func newDatasetsUploadOnFirstAutomaticRoundAndConvergeAfterConflict() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try await fixture.directory.saveDirectory(Self.directory())
        try await fixture.history.record(Self.visit())
        let server = WebDAVMemoryServer()
        server.conflictNextWrites(1)
        WebDAVTestURLProtocol.setHandler(for: fixture.host, emulatesConditionalSupport: false, server.respond)
        defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }
        let service = fixture.service()
        #expect(try await service.synchronizeAutomatically(bypassingMinimumInterval: true) == .uploaded)
        #expect(server.data("yamibox-manga-directories-v1.json") != nil)
        #expect(server.data("yamibox-browsing-history-v1.json") != nil)
        let writes = server.payloadWriteCount
        _ = try await service.synchronizeAutomatically(bypassingMinimumInterval: true)
        #expect(server.payloadWriteCount == writes)
        #expect(server.probeFileCount == 0)
    }

    @Test(arguments: [true, false])
    func deletingHistoryOnlyPropagatesWhenEnabled(enabled: Bool) async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        let visit = Self.visit()
        try await fixture.history.record(visit)
        let participant = BrowsingHistoryWebDAVParticipant(store: fixture.history)
        let oldRemote = try await participant.mergeAndExport(remoteData: nil, updatedAt: .now, accountUID: "user")
        try await fixture.settings.setContent(.browsingHistory, enabled: enabled)
        try await fixture.history.delete(id: visit.id)
        let reopened = BrowsingHistoryStore(databasePool: fixture.pool, syncSettingsStore: fixture.settings)
        let snapshot = try await reopened.syncSnapshot()
        #expect(snapshot.deletions.tombstones.isEmpty == !enabled)
        try await fixture.settings.setContent(.browsingHistory, enabled: true)
        try await BrowsingHistoryWebDAVParticipant(store: reopened).applyRemote(oldRemote)
        #expect(await reopened.entries().isEmpty == enabled)
        #expect(try await !reopened.canRecord(BrowsingHistoryVisit(threadID: "100", title: "Visit", reader: .normal, date: visit.lastVisitTime), targetID: visit.id))
        try await reopened.record(Self.visit(at: .now.addingTimeInterval(1)))
        #expect(try await reopened.syncSnapshot().records.count == 1)
    }

    @Test(arguments: [true, false])
    func directoryDeletionDoesNotResurrectUnlessDisabled(enabled: Bool) async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        try await fixture.directory.saveDirectory(Self.directory())
        let participant = MangaDirectoryWebDAVParticipant(store: fixture.directory)
        let remote = try await participant.mergeAndExport(remoteData: nil, updatedAt: .now, accountUID: "user")
        try await fixture.settings.setContent(.mangaDirectories, enabled: enabled)
        try await fixture.directory.deleteDirectory(named: "Book")
        try await fixture.settings.setContent(.mangaDirectories, enabled: true)
        try await participant.applyRemote(remote)
        #expect(try await fixture.directory.directory(named: "Book") == (enabled ? nil : Self.directory()))
    }

    @Test func directoryMergeKeepsWholeNewerDirectoryAndDeterministicTies() throws {
        var old = Self.directory()
        old.chapters = [MangaChapter(tid: "2", rawTitle: "Second", chapterNumber: 2), MangaChapter(tid: "1", rawTitle: "First", chapterNumber: 1)]
        var new = old
        new.chapters = [old.chapters[1]]
        new.searchKeyword = "corrected"
        let a = MangaDirectoryWebDAVPayload(updatedAt: .now, records: [.init(directory: old, modifiedAt: Date(timeIntervalSince1970: 1))])
        let b = MangaDirectoryWebDAVPayload(updatedAt: .now, records: [.init(directory: new, modifiedAt: Date(timeIntervalSince1970: 2))])
        #expect(try a.merging(b).records.first?.directory == new)
        var tie = a
        tie.records[0].modifiedAt = b.records[0].modifiedAt
        #expect(try tie.merging(b).contentFingerprint() == b.merging(tie).contentFingerprint())
    }

    @Test func directoryRenameMarksOldNameWithoutLosingChapters() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        try await fixture.directory.saveDirectory(Self.directory())
        var renamed = Self.directory()
        renamed.cleanBookName = "Renamed"
        try await fixture.directory.renameDirectory(from: "Book", to: renamed)
        let snapshot = try await fixture.directory.syncSnapshot()
        #expect(snapshot.records.map(\.id) == ["Renamed"])
        #expect(snapshot.deletions.tombstones["Book"] != nil)
        #expect(snapshot.records[0].directory.chapters == renamed.chapters)
    }

    @Test func historyCapAndProjectionDoNotCreateSyncDeletionsOrFingerprintChanges() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        let records = (0..<2005).map { index in
            BrowsingHistorySyncRecord(BrowsingHistoryEntry(target: .normalThread(threadID: String(index)), title: "Visit", lastVisitTime: Date(timeIntervalSince1970: Double(index))))
        }
        let payload = BrowsingHistoryWebDAVPayload(updatedAt: .now, records: records)
        let participant = BrowsingHistoryWebDAVParticipant(store: fixture.history)
        try await participant.applyRemote(JSONEncoder().encode(payload))
        let snapshot = try await fixture.history.syncSnapshot()
        #expect(snapshot.records.count == 2000)
        #expect(snapshot.deletions == .init())
        let before = try await participant.readLocalFingerprint()
        let oldEntries = try await fixture.history.snapshotEntries()
        var projected = oldEntries
        projected[0].target = .novelThread(threadID: "2004")
        projected[0].chapterTitle = "Local position"
        #expect(try await fixture.history.applyCanonicalEntries(projected, replacing: oldEntries))
        #expect(try await participant.readLocalFingerprint() == before)
    }

    @Test func clearEmptyStoreRejectsOldRemoteAndResetErasesSyncState() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        let payload = BrowsingHistoryWebDAVPayload(updatedAt: .now, records: [BrowsingHistorySyncRecord(Self.visit())])
        try await fixture.history.clearAllForSync()
        try await BrowsingHistoryWebDAVParticipant(store: fixture.history).applyRemote(JSONEncoder().encode(payload))
        #expect(await fixture.history.entries().isEmpty)
        #expect(try await fixture.history.syncSnapshot().deletions.clearedAt != nil)
        try await fixture.history.clearAll()
        #expect(try await fixture.history.syncSnapshot().deletions == .init())
        try await fixture.directory.clearAllForSync()
        try await fixture.directory.clearAll()
        #expect(try await fixture.directory.syncSnapshot().deletions == .init())
    }

    @Test func futurePayloadVersionsAreRejected() throws {
        let directory = MangaDirectoryWebDAVPayload(version: 99, updatedAt: .now, records: [])
        let history = BrowsingHistoryWebDAVPayload(version: 99, updatedAt: .now, records: [])
        #expect(throws: WebDAVSyncError.unsupportedPayloadVersion(99)) { try MangaDirectoryWebDAVPayload.decode(JSONEncoder().encode(directory)) }
        #expect(throws: WebDAVSyncError.unsupportedPayloadVersion(99)) { try BrowsingHistoryWebDAVPayload.decode(JSONEncoder().encode(history)) }
    }

    @Test func selectionChangedDuringUploadAppliesNextRoundAndKeepsReenablePending() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        try await fixture.signIn()
        try await fixture.settings.setContent(.browsingHistory, enabled: false)
        let server = WebDAVMemoryServer()
        WebDAVTestURLProtocol.setHandler(for: fixture.host, emulatesConditionalSupport: false, server.respond)
        defer { WebDAVTestURLProtocol.removeHandler(for: fixture.host) }
        let store = fixture.settings
        let service = fixture.service(participants: [
            SelectionTestParticipant(datasetID: "readingProgress", onExport: {
                try await store.setContent(.browsingHistory, enabled: true)
            }),
            SelectionTestParticipant(datasetID: "browsingHistory")
        ])
        try await service.upload()
        #expect(server.data("browsingHistory.json") == nil)
        #expect(await store.load().dirtyDatasetIDs.contains("browsingHistory"))
        try await service.upload()
        #expect(server.data("browsingHistory.json") != nil)
    }

    @Test func deletionFailureRollsBackBothLocalAndSyncState() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        try await fixture.history.record(Self.visit())
        try await fixture.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_history_delete BEFORE DELETE ON browsing_history BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        await #expect(throws: (any Error).self) { try await fixture.history.delete(id: Self.visit().id) }
        let snapshot = try await fixture.history.syncSnapshot()
        #expect(snapshot.records.count == 1)
        #expect(snapshot.deletions == .init())
        #expect(try await fixture.history.canRecord(BrowsingHistoryVisit(threadID: "100", title: "Visit", reader: .normal, date: Self.visit().lastVisitTime), targetID: Self.visit().id))
    }

    @Test func remoteDeletionBlocksAnOlderInFlightVisit() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        let old = Self.visit()
        var state = SyncDeletionState()
        state.recordDeletion(of: BrowsingHistorySyncRecord(old).id, at: old.lastVisitTime.addingTimeInterval(1))
        let remote = BrowsingHistoryWebDAVPayload(updatedAt: .now, records: [], deletions: state)
        try await BrowsingHistoryWebDAVParticipant(store: fixture.history).applyRemote(JSONEncoder().encode(remote))
        try await fixture.history.record(old)
        #expect(await fixture.history.entries().isEmpty)
        #expect(try await fixture.history.syncSnapshot().records.isEmpty)
    }

    @Test func historyConvergesAcrossDevicesWithDifferentLocalProjections() async throws {
        let first = try ContentSyncFixture()
        let second = try ContentSyncFixture()
        defer { first.cleanup(); second.cleanup() }
        try await first.history.record(Self.visit())
        let a = BrowsingHistoryWebDAVParticipant(store: first.history)
        let b = BrowsingHistoryWebDAVParticipant(store: second.history)
        let uploaded = try await a.mergeAndExport(remoteData: nil, updatedAt: .now, accountUID: "user")
        try await b.applyRemote(uploaded)
        let original = try await second.history.snapshotEntries()
        var novel = original
        novel[0].target = .novelThread(threadID: "100")
        novel[0].chapterTitle = "Chapter on this device"
        #expect(try await second.history.applyCanonicalEntries(novel, replacing: original))
        let returned = try await b.mergeAndExport(remoteData: uploaded, updatedAt: .now, accountUID: "user")
        try await a.applyRemote(returned)
        #expect(try await a.readLocalFingerprint() == b.readLocalFingerprint())
        #expect(await first.history.entries().first?.target.kind == .normalThread)
        #expect(await second.history.entries().first?.target.kind == .novelThread)
        #expect(await first.history.entries().first?.chapterTitle == nil)
        #expect(try JSONSerialization.jsonObject(with: returned) as? [String: Any] != nil)
        #expect(!String(decoding: returned, as: UTF8.self).contains("pageIndex"))
    }

    @Test func unchangedHistorySyncPreservesCollapsedLocalProjection() async throws {
        let fixture = try ContentSyncFixture()
        defer { fixture.cleanup() }
        try await fixture.history.record(Self.visit())
        try await fixture.history.record(BrowsingHistoryEntry(
            target: .normalThread(threadID: "200"), title: "Second chapter",
            lastVisitTime: Date(timeIntervalSince1970: 200)))
        let participant = BrowsingHistoryWebDAVParticipant(store: fixture.history)
        let remote = try await participant.mergeAndExport(remoteData: nil, updatedAt: .now, accountUID: "user")
        let entries = try await fixture.history.snapshotEntries()
        var collapsed = try #require(entries.first)
        collapsed.target = FavoriteContentTarget(mangaCleanBookName: "Book")
        #expect(try await fixture.history.applyCanonicalEntries([collapsed], replacing: entries))
        try await participant.applyRemote(remote)
        #expect(try await fixture.history.snapshotEntries() == [collapsed])
        #expect(try await fixture.history.syncSnapshot().records.count == 2)
    }

    @Test func migrationBackfillsVisitsAndDirectoryModificationTimes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webdav-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: root.appendingPathComponent("db.sqlite").path)
        var readerMigrator = DatabaseMigrator()
        ReaderDatabaseSchema.registerMigrations(in: &readerMigrator)
        try readerMigrator.migrate(pool, upTo: "reader.v3.sync-deletions")
        var historyMigrator = DatabaseMigrator()
        BrowsingHistoryDatabaseSchema.registerMigrations(in: &historyMigrator)
        try historyMigrator.migrate(pool, upTo: "history.v2.source")
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO manga_directories (clean_book_name, strategy, source_key, last_updated_at) VALUES ('Old', 'links', 'old', 123)")
            try db.execute(sql: "INSERT INTO browsing_history (id, target_kind, thread_id, category, title, last_visit_time) VALUES ('thread:normal:1', 'normalThread', '1', 'normal', 'Old visit', 123)")
        }
        try readerMigrator.migrate(pool)
        try historyMigrator.migrate(pool)
        let history = BrowsingHistoryStore(databasePool: pool)
        let directory = MangaDirectoryStore(databasePool: pool)
        #expect(try await history.syncSnapshot().records.first?.title == "Old visit")
        #expect(try await directory.syncSnapshot().records.first?.modifiedAt == Date(timeIntervalSince1970: 123))
    }

    @Test func legacySyncFactsMigrationPreservesVisitsAndDeletionState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try Self.makeLegacyHistoryPool(root: root)
        let archived = Self.visit(at: Date(timeIntervalSince1970: 300))
        let deleted = BrowsingHistoryEntry(target: .normalThread(threadID: "200"), title: "Deleted",
            lastVisitTime: Date(timeIntervalSince1970: 100))
        var deletions = SyncDeletionState()
        deletions.recordDeletion(of: deleted.id, at: Date(timeIntervalSince1970: 200))
        let expectedDeletions = deletions
        try await pool.write { db in
            for entry in [archived, deleted] {
                try db.execute(sql: "INSERT INTO browsing_history_sync_records (id, payload, target_id) VALUES (?, ?, ?)",
                    arguments: [entry.id, try JSONEncoder().encode(entry), entry.id])
            }
            try expectedDeletions.save(to: "browsing_history_sync_state", in: db)
        }
        try YamiboDatabase.migrate(pool)
        try YamiboDatabase.migrate(pool)
        let store = BrowsingHistoryStore(databasePool: pool)
        let snapshot = try await store.syncSnapshot()
        #expect(snapshot.deletions == expectedDeletions)
        #expect(snapshot.records.count == 2)
        #expect(snapshot.records.contains(BrowsingHistorySyncRecord(archived)))
        #expect(!snapshot.records.contains { $0.id == "source:200" })
        #expect(await store.entries().map(\.title) == ["Live visit"])
        let reopened = BrowsingHistoryStore(databasePool: try YamiboDatabase.openPool(rootDirectory: root))
        #expect(try await reopened.syncSnapshot() == snapshot)
        #expect(try await BrowsingHistoryWebDAVParticipant(store: reopened).readLocalFingerprint() != nil)
    }

    @Test func malformedLegacyHistoryRollsBackWithoutDiscardingRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-history-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try Self.makeLegacyHistoryPool(root: root)
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO browsing_history_sync_records (id, payload, target_id) VALUES ('old', ?, 'old')",
                arguments: [Data("invalid".utf8)])
        }
        #expect(throws: (any Error).self) { try YamiboDatabase.migrate(pool) }
        try await pool.read { db throws -> Void in
            #expect(try Data.fetchOne(db, sql: "SELECT payload FROM browsing_history_sync_records") == Data("invalid".utf8))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM browsing_history") == 1)
            #expect(try !db.tableExists("browsing_history_local_deletions"))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'history.v3.webdav'") == 0)
        }
    }

    private static func makeLegacyHistoryPool(root: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: root.appendingPathComponent("yamibox.sqlite").path)
        var migrator = DatabaseMigrator()
        ReaderDatabaseSchema.registerMigrations(in: &migrator)
        BrowsingHistoryDatabaseSchema.registerMigrations(in: &migrator)
        try migrator.migrate(pool, upTo: "history.v2.source")
        try pool.write { db in
            try SyncDeletionState.createTable("browsing_history_sync_state", in: db)
            try db.execute(sql: "CREATE TABLE browsing_history_sync_records (id TEXT PRIMARY KEY ON CONFLICT REPLACE, payload BLOB NOT NULL, target_id TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('history.v3.sync-facts')")
            try db.execute(sql: "INSERT INTO browsing_history (id, target_kind, thread_id, category, title, last_visit_time) VALUES ('thread:normal:300', 'normalThread', '300', 'normal', 'Live visit', 123)")
        }
        return pool
    }

    private static func directory() -> MangaDirectory {
        MangaDirectory(cleanBookName: "Book", strategy: .links, sourceKey: "book", chapters: [MangaChapter(tid: "100", rawTitle: "Chapter", chapterNumber: 1)])
    }

    private static func visit(at date: Date = Date(timeIntervalSince1970: 100)) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(target: .normalThread(threadID: "100"), title: "Visit", pageIndex: 8, lastVisitTime: date)
    }
}

private struct ContentSyncFixture {
    let root: URL
    let suite: String
    let host: String
    let pool: DatabasePool
    let settings: WebDAVSyncSettingsStore
    let session: SessionStore
    let directory: MangaDirectoryStore
    let history: BrowsingHistoryStore

    init() throws {
        suite = "content-sync-\(UUID().uuidString)"
        host = "\(suite).example.com".lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        pool = try YamiboDatabase.openPool(rootDirectory: root)
        settings = WebDAVSyncSettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        session = SessionStore(defaults: try #require(UserDefaults(suiteName: suite)))
        directory = MangaDirectoryStore(databasePool: pool, syncSettingsStore: settings)
        history = BrowsingHistoryStore(databasePool: pool, syncSettingsStore: settings)
    }

    func cleanup() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func signIn() async throws {
        try await settings.save(WebDAVSyncSettings(baseURLString: "https://\(host)", username: "user", password: "password", isAutoSyncEnabled: true))
        try await session.save(SessionState(cookie: "sid=user", isLoggedIn: true, accountUID: "user"))
    }

    func service(participants: [any WebDAVSyncParticipant]? = nil) -> WebDAVSyncService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVTestURLProtocol.self]
        return WebDAVSyncService(settingsStore: settings, sessionStore: session,
            participants: participants ?? [MangaDirectoryWebDAVParticipant(store: directory), BrowsingHistoryWebDAVParticipant(store: history)],
            client: WebDAVClient(session: URLSession(configuration: configuration)))
    }
}

private struct SelectionTestParticipant: WebDAVSyncParticipant {
    let datasetID: String
    var onExport: (@Sendable () async throws -> Void)?
    var remoteFileName: String { "\(datasetID).json" }
    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo { WebDAVRemotePayloadInfo(updatedAt: .distantPast) }
    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> WebDAVExportSnapshot {
        try await onExport?()
        return WebDAVExportSnapshot(data: Data("{}".utf8), fingerprint: nil)
    }
    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot { WebDAVApplySnapshot(fingerprint: nil, requiresUpload: false) }
}

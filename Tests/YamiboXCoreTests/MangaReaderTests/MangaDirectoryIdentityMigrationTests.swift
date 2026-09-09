import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Suite("MangaReaderTests: Directory Identity Transaction")
struct MangaDirectoryIdentityMigrationTests {
    @Test(arguments: [false, true])
    func failureAtDirectoryRemovalRollsBackEveryDomainAndPublishesNothing(existingDestination: Bool) async throws {
        let fixture = try DirectoryMigrationFixture()
        defer { fixture.cleanup() }
        try await fixture.seed(existingDestination: existingDestination)
        let before = try await fixture.snapshot()
        let signals = MigrationSignals(fixture: fixture)
        defer { signals.cancel() }
        try await fixture.database.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER fail_directory_migration
                BEFORE DELETE ON manga_directories
                WHEN OLD.clean_book_name = 'Old'
                BEGIN SELECT RAISE(ABORT, 'injected directory migration failure'); END
                """)
        }

        await #expect(throws: DatabaseError.self) {
            try await fixture.directoryStore.renameDirectory(from: "Old", to: fixture.renamedDirectory)
        }

        #expect(try await fixture.snapshot() == before)
        try await signals.settle()
        #expect(await signals.counts() == [:])
    }

    @Test(arguments: [false, true])
    func successfulRenameCommitsAllDomainsAndPublishesEachSignalOnce(existingDestination: Bool) async throws {
        let fixture = try DirectoryMigrationFixture()
        defer { fixture.cleanup() }
        try await fixture.seed(existingDestination: existingDestination)
        let signals = MigrationSignals(fixture: fixture)
        defer { signals.cancel() }

        try await fixture.directoryStore.renameDirectory(from: "Old", to: fixture.renamedDirectory)

        let after = try await fixture.snapshot()
        #expect(after.oldDirectory == nil)
        #expect(after.newDirectory == fixture.renamedDirectory)
        #expect(after.progress.records.count == 1)
        #expect(after.progress.records.first?.contentTarget?.mangaCleanBookName == "New")
        #expect(after.progress.records.first?.manga?.mangaPageIndex == (existingDestination ? 9 : 6))
        #expect(after.progress.deletions.tombstones[FavoriteContentTarget(mangaCleanBookName: "Old").id] != nil)
        #expect(after.covers.records.map(\.key) == [.smartManga(cleanBookName: "New")])
        #expect(after.covers.records.first?.manualCoverURL?.lastPathComponent == (existingDestination ? "new.jpg" : "old.jpg"))
        #expect(after.covers.deletions.tombstones[ContentCoverKey.smartManga(cleanBookName: "Old").syncID] != nil)
        #expect(after.likes.records.first(where: { $0.id == "live-like" })?.workKey == .mangaTitle(cleanBookName: "New"))
        #expect(after.likes.records.first(where: { $0.id == "deleted-like" })?.workKey == .mangaTitle(cleanBookName: "Old"))
        #expect(after.bookmarks.records.first(where: { $0.id == "live-bookmark" })?.workKey == .mangaTitle(cleanBookName: "New"))
        #expect(after.bookmarks.records.first(where: { $0.id == "deleted-bookmark" })?.workKey == .mangaTitle(cleanBookName: "Old"))
        #expect(after.updates.trackedTargets.map(\.target) == [.mangaDirectory(cleanBookName: "New")])
        let expectedChapterTIDs: Set<String> = existingDestination ? ["100", "200"] : ["100"]
        #expect(after.updates.trackedTargets.first?.knownChapterTIDs == expectedChapterTIDs)
        #expect(after.updates.events.count == 1)
        #expect(after.updates.events.first?.target == .mangaDirectory(cleanBookName: "New"))
        #expect(after.updates.events.first?.title == "New")
        try await signals.waitForAllSignals()
        try await signals.settle()
        #expect(await signals.counts() == ["directory": 1, "progress": 1, "updates": 1])
    }

    @Test func unchangedNameDoesNotPublishAnIdentityProgressChange() async throws {
        let fixture = try DirectoryMigrationFixture()
        defer { fixture.cleanup() }
        try await fixture.seed(existingDestination: false)
        let before = try await fixture.progressStore.syncSnapshot()
        let signals = MigrationSignals(fixture: fixture)
        defer { signals.cancel() }

        try await fixture.directoryStore.renameDirectory(from: "Old", to: fixture.originalDirectory)

        #expect(try await fixture.progressStore.syncSnapshot() == before)
        try await signals.settle()
        #expect(await signals.counts() == ["directory": 1, "updates": 1])
    }
}

private struct DirectoryMigrationFixture: Sendable {
    let root: URL
    let database: DatabasePool
    let directoryStore: MangaDirectoryStore
    let progressStore: ReadingProgressStore
    let coverStore: ContentCoverStore
    let likeStore: LikeStore
    let bookmarkStore: BookmarkStore
    let updateStore: FavoriteUpdateStore

    let originalDirectory = MangaDirectory(
        cleanBookName: "Old",
        strategy: .links,
        sourceKey: "source",
        chapters: [MangaChapter(tid: "100", rawTitle: "First", chapterNumber: 1, view: 2)]
    )

    var renamedDirectory: MangaDirectory {
        var directory = originalDirectory
        directory.cleanBookName = "New"
        directory.chapters.append(MangaChapter(tid: "200", rawTitle: "Second", chapterNumber: 2, view: 3))
        return directory
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("directory-identity-\(UUID().uuidString)", isDirectory: true)
        database = try YamiboDatabase.openPool(rootDirectory: root)
        progressStore = ReadingProgressStore(databasePool: database)
        coverStore = ContentCoverStore(databasePool: database)
        likeStore = LikeStore(databasePool: database)
        bookmarkStore = BookmarkStore(databasePool: database)
        updateStore = FavoriteUpdateStore(databasePool: database)
        directoryStore = MangaDirectoryStore(
            databasePool: database,
            favoriteUpdateStore: updateStore,
            readingProgressStore: progressStore
        )
    }

    func seed(existingDestination: Bool) async throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 1_500)
        try await directoryStore.saveDirectory(originalDirectory)
        try await progressStore.saveMangaTitle(cleanBookName: "Old", chapterThreadID: "100", chapterView: 2,
                                              chapterTitle: "First", pageIndex: 6, date: old)
        try await coverStore.setManualCover(try #require(URL(string: "https://example.com/old.jpg")),
                                            for: .smartManga(cleanBookName: "Old"), date: old)
        let key = LikeWorkKey.mangaTitle(cleanBookName: "Old")
        let like = LikeItem(id: "live-like", workKey: key, kind: .image,
                            anchor: .mangaImage(MangaImageLikeAnchor(chapterTID: "100", pageLocalIndex: 6)),
                            createdAt: old, updatedAt: old)
        var deletedLike = like
        deletedLike.id = "deleted-like"
        deletedLike.deletedAt = newer
        deletedLike.updatedAt = newer
        try await likeStore.replaceAll([like, deletedLike])
        let bookmark = BookmarkItem(id: "live-bookmark", workKey: key,
                                    anchor: .manga(MangaBookmarkAnchor(chapterTID: "100", pageLocalIndex: 6, globalPageIndex: 6)),
                                    createdAt: old, updatedAt: old)
        var deletedBookmark = bookmark
        deletedBookmark.id = "deleted-bookmark"
        deletedBookmark.deletedAt = newer
        deletedBookmark.updatedAt = newer
        try await bookmarkStore.replaceAll([bookmark, deletedBookmark])
        try await updateStore.upsertTrackedTarget(FavoriteUpdateTrackedTarget(
            target: .mangaDirectory(cleanBookName: "Old"), title: "Old", mode: .mangaDirectory,
            knownChapterTIDs: ["100"], baselineReady: true
        ))
        try await updateStore.insertEvent(FavoriteUpdateEvent(
            target: .mangaDirectory(cleanBookName: "Old"), title: "Old", mode: .mangaDirectory,
            summary: .newChapters(count: 1), detailIDs: ["200"]
        ))
        if existingDestination {
            try await directoryStore.saveDirectory(MangaDirectory(
                cleanBookName: "New", strategy: .tag, sourceKey: "destination",
                chapters: [MangaChapter(tid: "300", rawTitle: "Existing", chapterNumber: 3, view: 1)]
            ))
            try await progressStore.saveMangaTitle(cleanBookName: "New", chapterThreadID: "300", chapterView: 1,
                                                  chapterTitle: "Existing", pageIndex: 9, date: newer)
            try await coverStore.setManualCover(try #require(URL(string: "https://example.com/new.jpg")),
                                                for: .smartManga(cleanBookName: "New"), date: newer)
            try await updateStore.upsertTrackedTarget(FavoriteUpdateTrackedTarget(
                target: .mangaDirectory(cleanBookName: "New"), title: "New", mode: .mangaDirectory,
                knownChapterTIDs: ["200"], baselineReady: true
            ))
        }
    }

    func snapshot() async throws -> DirectoryMigrationSnapshot {
        DirectoryMigrationSnapshot(
            oldDirectory: try await directoryStore.directory(named: "Old"),
            newDirectory: try await directoryStore.directory(named: "New"),
            progress: try await progressStore.syncSnapshot(),
            covers: try await coverStore.syncSnapshot(),
            likes: try await likeStore.syncSnapshot(),
            bookmarks: try await bookmarkStore.syncSnapshot(),
            updates: await updateStore.loadState()
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct DirectoryMigrationSnapshot: Equatable, Sendable {
    let oldDirectory: MangaDirectory?
    let newDirectory: MangaDirectory?
    let progress: SyncRecordSnapshot<ReadingProgressRecord>
    let covers: SyncRecordSnapshot<ContentCover>
    let likes: SyncRecordSnapshot<LikeItem>
    let bookmarks: SyncRecordSnapshot<BookmarkItem>
    let updates: FavoriteUpdateStoreState
}

private struct MigrationSignals: Sendable {
    private let probe: MigrationSignalProbe
    private let tasks: [Task<Void, Never>]

    init(fixture: DirectoryMigrationFixture) {
        let probe = MigrationSignalProbe()
        self.probe = probe
        let streams = [
            ("directory", fixture.directoryStore.changes()),
            ("progress", fixture.progressStore.changes()),
            ("updates", fixture.updateStore.changes())
        ]
        tasks = streams.map { name, stream in
            Task { [probe] in
                for await _ in stream {
                    await probe.record(name)
                }
            }
        }
    }

    func counts() async -> [String: Int] { await probe.counts }

    func waitForAllSignals() async throws {
        for _ in 0..<200 {
            if await probe.counts.values.reduce(0, +) >= 3 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MigrationSignalError.timedOut
    }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(25))
    }

    func cancel() {
        for task in tasks { task.cancel() }
    }
}

private actor MigrationSignalProbe {
    private(set) var counts: [String: Int] = [:]

    func record(_ name: String) {
        counts[name, default: 0] += 1
    }
}

private enum MigrationSignalError: Error {
    case timedOut
}

import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Suite("Canonical browsing history")
struct BrowsingHistoryWorkflowTests {
    @Test(arguments: [BoardReaderSettings.ReaderMode.normal, .novel, .manga(smartEnabled: false), .manga(smartEnabled: true)], BrowsingHistoryCategory.allCases)
    func boardModeOwnsIdentityAndPosition(mode: BoardReaderSettings.ReaderMode, reader: BrowsingHistoryCategory) async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(mode)
        try await fixture.directories.saveDirectory(fixture.directory)
        try await fixture.progress.saveNormalThread(threadID: "101", page: 7, pageCount: 20)
        try await fixture.progress.saveNovel(NovelReadingPosition(threadID: "101", view: 3, chapterTitle: "Novel chapter"))
        try await fixture.progress.saveMangaThread(MangaProgressReadingPosition(chapterThreadID: "101", chapterTitle: "Thread manga", pageIndex: 8, pageCount: 30))
        try await fixture.progress.saveMangaTitle(cleanBookName: "Book", chapterThreadID: "102", chapterTitle: "Directory chapter", pageIndex: 11, pageCount: 40, mangaID: fixture.directory.favoriteIdentity)
        try await fixture.workflow.recordVisit(fixture.visit(reader: reader))
        let snapshot = try await fixture.workflow.snapshot()
        let entry = try #require(snapshot.entries.first)
        #expect(snapshot.entries.count == 1)
        #expect(entry.lastVisitedThreadID == "101")
        #expect(entry.forumID == "40")
        switch mode {
        case .normal:
            #expect(entry.target == .normalThread(threadID: "101"))
            #expect(entry.pageIndex == 7)
            #expect(entry.chapterTitle == nil)
        case .novel:
            #expect(entry.target == .novelThread(threadID: "101"))
            #expect(entry.chapterTitle == "Novel chapter")
            #expect(entry.pageIndex == nil)
        case .manga(smartEnabled: false):
            #expect(entry.target == .mangaThread(threadID: "101"))
            #expect(entry.pageIndex == 8)
        case .manga(smartEnabled: true):
            #expect(entry.target == fixture.directoryTarget)
            #expect(entry.chapterThreadID == "102")
            #expect(entry.pageIndex == 11)
        }
    }

    @Test func temporaryModesOnlyRefreshOneCanonicalVisit() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(.novel)
        let adapter = FavoriteLibraryProgressSyncAdapter(readingProgressStore: fixture.progress, browsingHistoryWorkflow: fixture.workflow)
        for reader in BrowsingHistoryCategory.allCases {
            try await fixture.workflow.recordVisit(fixture.visit(reader: reader))
        }
        try await adapter.saveMangaReadingPosition(MangaProgressReadingPosition(chapterThreadID: "101", chapterTitle: "Manga", pageIndex: 12, isSmartModeEnabled: false))
        var entries = try await fixture.workflow.snapshot().entries
        #expect(entries.count == 1)
        #expect(entries[0].category == .novel)
        #expect(entries[0].pageIndex == nil)
        #expect(entries[0].chapterTitle == nil)
        try await adapter.saveNovelReadingPosition(NovelReadingPosition(threadID: "101", view: 2, chapterTitle: "Novel"))
        entries = try await fixture.workflow.snapshot().entries
        #expect(entries[0].chapterTitle == "Novel")
        #expect(await fixture.progress.load(for: .mangaThread(threadID: "101"))?.manga?.mangaPageIndex == 12)
    }

    @Test func directoryDiscoveryRenameAndModeChangesKeepRealVisit() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(.manga(smartEnabled: true))
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        try await fixture.workflow.recordVisit(fixture.visit(date: earlier))
        try await fixture.workflow.recordVisit(fixture.visit(tid: "102", date: later))
        #expect(try await fixture.workflow.snapshot().entries.count == 2)
        try await fixture.directories.saveDirectory(fixture.directory)
        var entries = try await fixture.workflow.snapshot().entries
        #expect(entries.count == 1)
        #expect(entries[0].target == fixture.directoryTarget)
        #expect(entries[0].lastVisitedThreadID == "102")
        #expect(entries[0].lastVisitTime == later)
        var renamed = fixture.directory
        renamed.cleanBookName = "Renamed"
        renamed.sourceKey = "resolved-source"
        try await fixture.directories.renameDirectory(from: "Book", to: renamed)
        entries = try await fixture.workflow.snapshot().entries
        #expect(entries.count == 1)
        #expect(entries[0].target.mangaID == renamed.favoriteIdentity)
        #expect(entries[0].title == "Renamed")
        #expect(entries[0].lastVisitTime == later)
        try await fixture.progress.saveNormalThread(threadID: "102", page: 4)
        for mode in [BoardReaderSettings.ReaderMode.manga(smartEnabled: false), .normal, .novel] {
            try await fixture.setMode(mode)
            entries = try await fixture.workflow.snapshot().entries
            #expect(entries.count == 1)
            #expect(entries[0].target.threadID == "102")
            #expect(entries[0].title == "Chapter 102")
            #expect(entries[0].lastVisitTime == later)
            #expect(entries[0].pageIndex == (mode == .normal ? 4 : nil))
        }
    }

    @Test func unknownBoardKeepsIdentityUntilLocalMetadataArrives() async throws {
        let metadata = HistoryForumMetadata()
        let fixture = try HistoryWorkflowFixture(resolveForumIDs: { tids in await metadata.resolve(tids) })
        var visit = fixture.visit(reader: .novel)
        visit.forumID = nil
        try await fixture.workflow.recordVisit(visit)
        var entries = try await fixture.workflow.snapshot().entries
        #expect(entries[0].category == .novel)
        visit.reader = .manga
        try await fixture.workflow.recordVisit(visit)
        #expect(try await fixture.workflow.snapshot().entries[0].category == .novel)
        await metadata.setForumID("88")
        entries = try await fixture.workflow.snapshot().entries
        #expect(entries[0].forumID == "88")
        #expect(entries[0].category == .normal)
        #expect(entries[0].lastVisitTime.timeIntervalSince1970 == visit.date.timeIntervalSince1970)
    }

    @Test func offlineDirectoryEvidenceMergesWithoutGuessingFromTitles() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(.manga(smartEnabled: true))
        for tid in ["101", "102"] {
            var visit = fixture.visit(tid: tid)
            visit.title = "Same title"
            try await fixture.workflow.recordVisit(visit)
        }
        #expect(try await fixture.workflow.snapshot().entries.count == 2)
        var visit = fixture.visit(tid: "102")
        visit.directory = fixture.directory
        try await fixture.workflow.updateActivity(visit)
        let snapshot = try await fixture.workflow.snapshot()
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].target == fixture.directoryTarget)
        #expect(snapshot.entries[0].lastVisitedThreadID == "102")
    }

    @Test func staleActivitiesAndDeletionCannotRecreateOrReorderHistory() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(.novel)
        let latest = fixture.visit(date: .now)
        try await fixture.workflow.recordVisit(latest)
        let stale = fixture.visit(reader: .manga, date: latest.date.addingTimeInterval(-10))
        try await fixture.workflow.updateActivity(stale)
        #expect(try await fixture.workflow.snapshot().entries[0].lastVisitTime.timeIntervalSince1970 == latest.date.timeIntervalSince1970)
        let beforeDelete = try await fixture.history.snapshotEntries()
        try await fixture.history.delete(id: beforeDelete[0].id)
        #expect(try await fixture.history.applyCanonicalEntries(beforeDelete, replacing: beforeDelete) == false)
        try await fixture.workflow.recordVisit(stale)
        try await fixture.workflow.updateActivity(fixture.visit())
        try await fixture.setMode(.manga(smartEnabled: true))
        try await fixture.directories.saveDirectory(fixture.directory)
        #expect(try await fixture.workflow.snapshot().entries.isEmpty)
        #expect(try await fixture.history.snapshotEntries().isEmpty)
        try await fixture.workflow.recordVisit(fixture.visit(date: Date.now.addingTimeInterval(1)))
        #expect(try await fixture.workflow.snapshot().entries.count == 1)
    }

    @Test func commentProgressDoesNotTouchHistoryButStillSavesResume() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(.novel)
        let visit = fixture.visit()
        try await fixture.workflow.recordVisit(visit)
        let adapter = FavoriteLibraryProgressSyncAdapter(readingProgressStore: fixture.progress, browsingHistoryWorkflow: fixture.workflow)
        try await adapter.saveThreadReadingPosition(ThreadReadingPosition(threadID: "101", page: 9, recordsBrowsingHistory: false))
        let entry = try #require(try await fixture.workflow.snapshot().entries.first)
        // Persistence stores Unix seconds; converting Date's reference epoch can round.
        #expect(entry.lastVisitTime.timeIntervalSince1970 == visit.date.timeIntervalSince1970)
        #expect(entry.pageIndex == nil)
        #expect(await fixture.progress.load(for: .normalThread(threadID: "101"))?.thread?.lastPage == 9)
    }

    @Test func deletingAVisibleRowFollowsItsChangedCanonicalIdentity() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(.novel)
        try await fixture.workflow.recordVisit(fixture.visit())
        let visible = try #require(try await fixture.workflow.snapshot().entries.first)
        try await fixture.setMode(.manga(smartEnabled: true))
        try await fixture.directories.saveDirectory(fixture.directory)
        _ = try await fixture.workflow.snapshot()
        try await fixture.workflow.delete(visible)
        #expect(try await fixture.workflow.snapshot().entries.isEmpty)
    }

    @Test func debouncedProgressKeepsItsOriginalActivityTime() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(.novel)
        try await fixture.workflow.recordVisit(fixture.visit())
        let sync = ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(readingProgressStore: fixture.progress, browsingHistoryWorkflow: fixture.workflow),
            debounceNanoseconds: 60_000_000_000
        )
        await sync.queue(.thread(ThreadReadingPosition(threadID: "101", page: 3)))
        let newerVisit = fixture.visit(reader: .novel)
        try await fixture.workflow.recordVisit(newerVisit)
        try await sync.flush()
        #expect(try await fixture.workflow.snapshot().entries[0].lastVisitTime.timeIntervalSince1970 == newerVisit.date.timeIntervalSince1970)
    }

    @Test func completedOldFlushCannotReplaceANewerQueuedPosition() async throws {
        let fixture = try HistoryWorkflowFixture()
        let gate = HistoryResolutionGate()
        let adapter = GatedHistoryProgressAdapter(
            base: FavoriteLibraryProgressSyncAdapter(readingProgressStore: fixture.progress, browsingHistoryWorkflow: fixture.workflow),
            gate: gate
        )
        let sync = ProgressSyncModule(adapter: adapter, debounceNanoseconds: 60_000_000_000)
        await gate.arm()
        let saving = Task { try await sync.flush(.novel(NovelReadingPosition(threadID: "101", view: 1))) }
        await gate.waitUntilBlocked()
        await sync.queue(.novel(NovelReadingPosition(threadID: "101", view: 2)))
        await gate.release()
        try await saving.value
        try await sync.flush()
        #expect(await fixture.progress.load(for: .novelThread(threadID: "101"))?.novel?.lastView == 2)
    }

    @Test(arguments: BrowsingHistoryCategory.allCases)
    func lateProgressCannotOverwriteNewerPosition(reader: BrowsingHistoryCategory) async throws {
        let fixture = try HistoryWorkflowFixture()
        let mode: BoardReaderSettings.ReaderMode
        switch reader {
        case .normal: mode = .normal
        case .novel: mode = .novel
        case .manga: mode = .manga(smartEnabled: false)
        }
        try await fixture.setMode(mode)
        let latestDate = Date.now
        try await fixture.workflow.recordVisit(fixture.visit(date: latestDate.addingTimeInterval(-20)))
        let adapter = FavoriteLibraryProgressSyncAdapter(readingProgressStore: fixture.progress, browsingHistoryWorkflow: fixture.workflow)
        func position(_ page: Int) -> ProgressSyncPosition {
            switch reader {
            case .normal: .thread(ThreadReadingPosition(threadID: "101", page: page))
            case .novel: .novel(NovelReadingPosition(threadID: "101", view: page, chapterTitle: "Chapter \(page)"))
            case .manga: .manga(MangaProgressReadingPosition(chapterThreadID: "101", chapterTitle: "Manga", pageIndex: page, isSmartModeEnabled: false))
            }
        }
        try await adapter.saveReadingPosition(position(7), activityDate: latestDate)
        try await adapter.saveReadingPosition(position(2), activityDate: latestDate.addingTimeInterval(-10))
        let entry = try #require(try await fixture.workflow.snapshot().entries.first)
        #expect(entry.lastVisitTime.timeIntervalSince1970 == latestDate.timeIntervalSince1970)
        if reader == .novel { #expect(entry.chapterTitle == "Chapter 7") }
        else { #expect(entry.pageIndex == 7) }
    }

    @Test func concurrentVisitsAndSettingsConvergeWithoutDuplicatingRows() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for offset in 0..<12 {
                group.addTask {
                    try await fixture.setMode(offset.isMultiple(of: 2) ? .novel : .normal)
                    try await fixture.workflow.recordVisit(fixture.visit(reader: .manga, date: Date(timeIntervalSince1970: Double(1_000 + offset))))
                }
            }
            try await group.waitForAll()
        }
        try await fixture.setMode(.novel)
        let snapshot = try await fixture.workflow.snapshot()
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].category == .novel)
        #expect(snapshot.entries[0].lastVisitTime == Date(timeIntervalSince1970: 1_011))
    }

    @Test(arguments: [false, true])
    func revalidatesAfterConcurrentConfigurationOrDeletion(deleteHistory: Bool) async throws {
        let gate = HistoryResolutionGate()
        let fixture = try HistoryWorkflowFixture(resolveForumIDs: { _ in
            await gate.pauseIfArmed()
            return [:]
        })
        try await fixture.setMode(.novel)
        let visit = fixture.visit()
        try await fixture.workflow.recordVisit(visit)
        await gate.arm()
        let loading = Task { try await fixture.workflow.snapshot() }
        await gate.waitUntilBlocked()
        try await fixture.setMode(.normal)
        if deleteHistory {
            try await fixture.history.delete(id: FavoriteContentTarget.novelThread(threadID: "101").id)
        }
        await gate.release()
        let result = try await loading.value
        if deleteHistory {
            #expect(result.entries.isEmpty)
        } else {
            #expect(result.entries.count == 1)
            #expect(result.entries[0].category == .normal)
            #expect(result.entries[0].lastVisitTime.timeIntervalSince1970 == visit.date.timeIntervalSince1970)
        }
    }

    @Test func observesSettingsWithoutAHistoryScreen() async throws {
        let fixture = try HistoryWorkflowFixture()
        try await fixture.setMode(.novel)
        let visit = fixture.visit()
        try await fixture.workflow.recordVisit(visit)
        let observation = Task { await fixture.workflow.observeChanges() }
        try await fixture.setMode(.normal)
        do {
            try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) {
                await fixture.history.entries().first?.category == .normal
            }
        } catch {
            observation.cancel()
            await observation.value
            throw error
        }
        observation.cancel()
        await observation.value
        #expect(await fixture.history.entries().first?.lastVisitTime.timeIntervalSince1970 == visit.date.timeIntervalSince1970)
    }
}

private final class HistoryWorkflowFixture: Sendable {
    let root: URL
    let settings: SettingsStore
    let history: BrowsingHistoryStore
    let progress: ReadingProgressStore
    let directories: MangaDirectoryStore
    let workflow: BrowsingHistoryWorkflow

    var directory: MangaDirectory {
        MangaDirectory(cleanBookName: "Book", strategy: .links, sourceKey: "source", chapters: [
            MangaChapter(tid: "101", rawTitle: "Chapter 101", chapterNumber: 1, view: 1),
            MangaChapter(tid: "102", rawTitle: "Chapter 102", chapterNumber: 2, view: 1)
        ])
    }
    var directoryTarget: FavoriteContentTarget {
        FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName)
    }

    init(resolveForumIDs: @escaping @Sendable ([String]) async -> [String: String] = { _ in [:] }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pool = try YamiboDatabase.openPool(rootDirectory: root)
        settings = try SettingsStore(testSuiteName: YamiboTestDefaults.suiteName(prefix: "canonical-history"), key: "settings")
        history = BrowsingHistoryStore(databasePool: pool)
        progress = ReadingProgressStore(databasePool: pool)
        directories = MangaDirectoryStore(databasePool: pool)
        workflow = BrowsingHistoryWorkflow(store: history, settingsStore: settings, progressStore: progress, directoryStore: directories, resolveForumIDs: resolveForumIDs)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func setMode(_ mode: BoardReaderSettings.ReaderMode) async throws {
        try await settings.update { $0.boardReader.setEntry(.init(mode: mode), forumID: "40") }
    }

    func visit(tid: String = "101", reader: BrowsingHistoryCategory = .normal, date: Date = .now) -> BrowsingHistoryVisit {
        BrowsingHistoryVisit(threadID: tid, title: "Chapter \(tid)", forumID: "40", reader: reader, date: date)
    }
}

private actor HistoryForumMetadata {
    private var forumID: String?
    func setForumID(_ value: String) { forumID = value }
    func resolve(_ tids: [String]) -> [String: String] {
        guard let forumID else { return [:] }
        return Dictionary(uniqueKeysWithValues: tids.map { ($0, forumID) })
    }
}

private actor HistoryResolutionGate {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() { armed = true }
    func pauseIfArmed() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilBlocked() async {
        while continuation == nil { await Task.yield() }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct GatedHistoryProgressAdapter: ProgressSyncAdapter {
    let base: FavoriteLibraryProgressSyncAdapter
    let gate: HistoryResolutionGate

    func saveReadingPosition(_ position: ProgressSyncPosition, activityDate: Date) async throws {
        await gate.pauseIfArmed()
        try await base.saveReadingPosition(position, activityDate: activityDate)
    }
    func saveNovelReadingPosition(_ position: NovelReadingPosition) async throws {
        try await base.saveNovelReadingPosition(position)
    }
    func saveMangaReadingPosition(_ position: MangaProgressReadingPosition) async throws {
        try await base.saveMangaReadingPosition(position)
    }
    func saveThreadReadingPosition(_ position: ThreadReadingPosition) async throws {
        try await base.saveThreadReadingPosition(position)
    }
}

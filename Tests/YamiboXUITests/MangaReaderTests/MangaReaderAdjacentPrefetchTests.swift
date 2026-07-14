import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class MangaReaderAdjacentPrefetchTests: XCTestCase {
    func testUpdateCurrentPageSchedulesAdjacentPrefetchNearEnd() async throws {
        let document700 = try makeAdjacentPrefetchDocument(tid: "700", pageCount: 10)
        let document701 = try makeAdjacentPrefetchDocument(tid: "701", pageCount: 1)
        let fixture = try await makeAdjacentPrefetchFixture(
            document: document700,
            extraDocuments: [document701],
            directory: makeAdjacentPrefetchDirectory(tids: ["700", "701"])
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 8)

        try await waitForAdjacentPrefetch {
            guard case let .loaded(loaded) = fixture.model.presentation.state else { return false }
            return loaded.pages.map(\.id).contains("701#0")
        }

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPage?.id, "700#8")
        XCTAssertEqual(loaded.viewportPlacement?.targetPageIndex, 8)
    }

    func testLocalPageJumpStaysInCurrentChapterAfterAdjacentPrefetch() async throws {
        let document700 = try makeAdjacentPrefetchDocument(tid: "700", pageCount: 4)
        let document701 = try makeAdjacentPrefetchDocument(tid: "701", pageCount: 4)
        let fixture = try await makeAdjacentPrefetchFixture(
            document: document700,
            extraDocuments: [document701],
            directory: makeAdjacentPrefetchDirectory(tids: ["700", "701"])
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 3)

        try await waitForAdjacentPrefetch {
            guard case let .loaded(loaded) = fixture.model.presentation.state else { return false }
            return loaded.pages.map(\.id).contains("701#1")
        }

        await fixture.model.jumpToPage(localIndex: 1)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPage?.id, "700#1")
        XCTAssertEqual(loaded.currentPageIndex, 1)
        XCTAssertEqual(loaded.viewportPlacement?.targetPageIndex, 1)
    }

    func testPreviousPrefetchKeepsCurrentPageIdentityAndStablePlacement() async throws {
        let document699 = try makeAdjacentPrefetchDocument(tid: "699", pageCount: 3)
        let document700 = try makeAdjacentPrefetchDocument(tid: "700", pageCount: 4)
        let fixture = try await makeAdjacentPrefetchFixture(
            document: document700,
            initialPage: 1,
            extraDocuments: [document699],
            directory: makeAdjacentPrefetchDirectory(tids: ["699", "700"])
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 1)

        try await waitForAdjacentPrefetch {
            guard case let .loaded(loaded) = fixture.model.presentation.state else { return false }
            return loaded.pages.first?.id == "699#0"
        }

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPage?.id, "700#1")
        XCTAssertEqual(loaded.currentPageIndex, 4)
        XCTAssertEqual(loaded.viewportPlacement?.targetPageIndex, 4)
        XCTAssertEqual(loaded.viewportPlacement?.animated, false)
    }

    func testDirectoryJumpSupersedesInFlightAdjacentPrefetch() async throws {
        let document700 = try makeAdjacentPrefetchDocument(tid: "700", pageCount: 10)
        let document701 = try makeAdjacentPrefetchDocument(tid: "701", pageCount: 1)
        let document702 = try makeAdjacentPrefetchDocument(tid: "702", pageCount: 1)
        let delayedTID = document701.tid
        let loader = AdjacentPrefetchProjectionLoader(
            documents: [document700, document701, document702],
            delayedTIDs: [delayedTID]
        )
        let directory = makeAdjacentPrefetchDirectory(tids: ["700", "701", "702"])
        let fixture = try await makeAdjacentPrefetchFixture(
            document: document700,
            loader: loader,
            directory: directory
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 8)
        try await waitForAdjacentPrefetch {
            await loader.hasRequested(delayedTID)
        }

        await fixture.model.jumpToChapter(directory.chapters[2])
        await loader.release(delayedTID)
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.pages.map(\.id), ["702#0"])
        XCTAssertEqual(loaded.currentPage?.id, "702#0")
        XCTAssertFalse(loaded.pages.map(\.tid).contains("701"))
    }

    func testDirectoryChapterDeleteSupersedesInFlightAdjacentPrefetch() async throws {
        let document700 = try makeAdjacentPrefetchDocument(tid: "700", pageCount: 10)
        let document701 = try makeAdjacentPrefetchDocument(tid: "701", pageCount: 1)
        let delayedTID = document701.tid
        let loader = AdjacentPrefetchProjectionLoader(
            documents: [document700, document701],
            delayedTIDs: [delayedTID]
        )
        let fixture = try await makeAdjacentPrefetchFixture(
            document: document700,
            loader: loader,
            directory: makeAdjacentPrefetchDirectory(tids: ["700", "701"])
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 8)
        try await waitForAdjacentPrefetch {
            await loader.hasRequested(delayedTID)
        }

        await fixture.model.deleteDirectoryChapters(tids: ["701"])
        await loader.release(delayedTID)
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.directoryPanel.displayChapters.map(\.tid), ["700"])
        XCTAssertEqual(loaded.pages.map(\.id), (0..<10).map { "700#\($0)" })
        XCTAssertFalse(loaded.pages.map(\.tid).contains("701"))
    }

    func testAdjacentPrefetchDoesNotDuplicateUnchangedProgress() async throws {
        let progressAdapter = RecordingAdjacentPrefetchProgressAdapter()
        let document700 = try makeAdjacentPrefetchDocument(tid: "700", pageCount: 10)
        let document701 = try makeAdjacentPrefetchDocument(tid: "701", pageCount: 1)
        let fixture = try await makeAdjacentPrefetchFixture(
            document: document700,
            extraDocuments: [document701],
            directory: makeAdjacentPrefetchDirectory(tids: ["700", "701"]),
            progressSync: ProgressSyncModule(adapter: progressAdapter, debounceNanoseconds: 0)
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 8)

        try await waitForAdjacentPrefetch {
            await progressAdapter.savedPositions.count == 1
        }

        try await waitForAdjacentPrefetch {
            guard case let .loaded(loaded) = fixture.model.presentation.state else { return false }
            return loaded.pages.map(\.id).contains("701#0")
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let savedPositions = await progressAdapter.savedPositions
        XCTAssertEqual(savedPositions.map(\.chapterThreadID), [document700.tid])
        XCTAssertEqual(savedPositions.map(\.chapterView), [document700.sourceIdentity.view])
        XCTAssertEqual(savedPositions.map(\.pageIndex), [8])
    }

    func testDirectoryJumpQueuesNewProgress() async throws {
        let progressAdapter = RecordingAdjacentPrefetchProgressAdapter()
        let document700 = try makeAdjacentPrefetchDocument(tid: "700", pageCount: 1)
        let document701 = try makeAdjacentPrefetchDocument(tid: "701", pageCount: 1)
        let directory = makeAdjacentPrefetchDirectory(tids: ["700", "701"])
        let fixture = try await makeAdjacentPrefetchFixture(
            document: document700,
            extraDocuments: [document701],
            directory: directory,
            progressSync: ProgressSyncModule(adapter: progressAdapter, debounceNanoseconds: 0)
        )

        await fixture.model.prepare()
        await fixture.model.jumpToChapter(directory.chapters[1])

        try await waitForAdjacentPrefetch {
            await progressAdapter.savedPositions.contains {
                $0.chapterThreadID == document701.tid &&
                    $0.chapterView == document701.sourceIdentity.view &&
                    $0.pageIndex == 0
            }
        }

        guard case let .manga(savedContext)? = await fixture.resumeRouteStore.load() else {
            XCTFail("Expected saved manga resume route")
            return
        }
        XCTAssertEqual(savedContext.chapterTID, "701")
        XCTAssertEqual(savedContext.initialPage, 0)
    }

    func testAdjacentPrefetchFailureDoesNotSetDirectoryPanelError() async throws {
        let document700 = try makeAdjacentPrefetchDocument(tid: "700", pageCount: 10)
        let missingTID = "701"
        let loader = AdjacentPrefetchProjectionLoader(documents: [document700])
        let fixture = try await makeAdjacentPrefetchFixture(
            document: document700,
            loader: loader,
            directory: makeAdjacentPrefetchDirectory(tids: ["700", "701"])
        )

        await fixture.model.prepare()
        fixture.model.updateCurrentPage(globalIndex: 8)
        try await waitForAdjacentPrefetch {
            await loader.hasRequested(missingTID)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.pages.map(\.id), (0..<10).map { "700#\($0)" })
        XCTAssertNil(loaded.directoryPanel.errorMessage)
    }
}

private struct AdjacentPrefetchFixture {
    let model: MangaReaderViewModel
    let resumeRouteStore: ReaderResumeRouteStore
}

@MainActor
private func makeAdjacentPrefetchFixture(
    document: MangaReaderProjection,
    initialPage: Int = 0,
    extraDocuments: [MangaReaderProjection] = [],
    loader: AdjacentPrefetchProjectionLoader? = nil,
    directory: MangaDirectory,
    progressSync: ProgressSyncModule? = nil
) async throws -> AdjacentPrefetchFixture {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-adjacent-prefetch")
    let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
    try await settingsStore.save(AppSettings())
    let resumeRouteStore = try ReaderResumeRouteStore(testSuiteName: defaultsSuiteName, key: "resume")
    let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
    let resolvedLoader = loader ?? AdjacentPrefetchProjectionLoader(documents: [document] + extraDocuments)
    let resolvedProgressSync = progressSync ?? ProgressSyncModule(
        adapter: FavoriteLibraryProgressSyncAdapter(
            readingProgressStore: readingProgressStore
        ),
        debounceNanoseconds: 0
    )
    #if os(iOS)
    let dependencies = MangaReaderViewModelDependencies(
        settingsStore: settingsStore,
        makeProjectionLoader: { resolvedLoader },
        makeDirectoryRepository: { AdjacentPrefetchDirectoryRepository(seed: makeAdjacentPrefetchSeed(document: document)) },
        makeDirectoryStore: { AdjacentPrefetchDirectoryStore(directories: [directory]) },
        makeDirectorySearchCooldownState: { MangaDirectorySearchCooldownState() },
        progressSync: resolvedProgressSync
    )
    #else
    let dependencies = MangaReaderViewModelDependencies(
        settingsStore: settingsStore,
        makeProjectionLoader: { resolvedLoader },
        makeDirectoryRepository: { AdjacentPrefetchDirectoryRepository(seed: makeAdjacentPrefetchSeed(document: document)) },
        makeDirectoryStore: { AdjacentPrefetchDirectoryStore(directories: [directory]) },
        makeDirectorySearchCooldownState: { MangaDirectorySearchCooldownState() },
        progressSync: resolvedProgressSync
    )
    #endif
    let context = MangaLaunchContext(
        originalThreadID: "700",
        chapterTID: document.tid,
        displayTitle: "测试漫画",
        source: .forum,
        initialPage: initialPage,
        directoryName: directory.cleanBookName
    )
    return AdjacentPrefetchFixture(
        model: MangaReaderViewModel(
            context: context,
            viewModelDependencies: dependencies,
            onReaderResumeRouteChange: { route in
                try? await resumeRouteStore.saveReadingPosition(route)
            }
        ),
        resumeRouteStore: resumeRouteStore
    )
}

private actor AdjacentPrefetchProjectionLoader: MangaReaderProjectionLoading {
    private let documents: [String: MangaReaderProjection]
    private let delayedTIDs: Set<String>
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var requestedTIDs: [String] = []

    init(documents: [MangaReaderProjection], delayedTIDs: Set<String> = []) {
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
        self.delayedTIDs = delayedTIDs
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        requestedTIDs.append(request.threadID)
        if delayedTIDs.contains(request.threadID) {
            await withCheckedContinuation { continuation in
                continuations[request.threadID] = continuation
            }
        }
        guard let document = documents[request.threadID] else {
            throw YamiboError.unreadableBody
        }
        return document
    }

    func hasRequested(_ threadID: String) -> Bool {
        requestedTIDs.contains(threadID)
    }

    func release(_ threadID: String) {
        continuations.removeValue(forKey: threadID)?.resume()
    }
}

private actor AdjacentPrefetchDirectoryRepository: MangaDirectoryRepository {
    private let seed: MangaDirectorySeed

    init(seed: MangaDirectorySeed) {
        self.seed = seed
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        seed
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        []
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        []
    }
}

private actor AdjacentPrefetchDirectoryStore: MangaDirectoryPersisting {
    private var directories: [String: MangaDirectory]

    init(directories: [MangaDirectory]) {
        self.directories = Dictionary(uniqueKeysWithValues: directories.map { ($0.cleanBookName, $0) })
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        directories[name.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        directories.values.first { directory in
            directory.chapters.contains { $0.tid == tid }
        }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {
        directories[directory.cleanBookName] = directory
    }

    func deleteDirectory(named name: String) async throws {
        directories.removeValue(forKey: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

#if os(iOS)
#endif

private actor RecordingAdjacentPrefetchProgressAdapter: ProgressSyncAdapter {
    private var saved: [MangaProgressReadingPosition] = []

    var savedPositions: [MangaProgressReadingPosition] {
        saved
    }

    func saveNovelReadingPosition(_ position: NovelReadingPosition) async throws {}

    func saveMangaReadingPosition(_ position: MangaProgressReadingPosition) async throws {
        saved.append(position)
    }

    func saveThreadReadingPosition(_ position: ThreadReadingPosition) async throws {}
}

private func makeAdjacentPrefetchDirectory(tids: [String]) -> MangaDirectory {
    MangaDirectory(
        cleanBookName: "Resolved Directory",
        strategy: .links,
        sourceKey: "Resolved Directory",
        chapters: tids.map { makeAdjacentPrefetchChapter(tid: $0) }
    )
}

private func makeAdjacentPrefetchChapter(tid: String) -> MangaChapter {
    MangaChapter(
        tid: tid,
        rawTitle: "第\(tid)话",
        chapterNumber: Double(tid) ?? 0
    )
}

private func makeAdjacentPrefetchSeed(document: MangaReaderProjection) -> MangaDirectorySeed {
    MangaDirectorySeed(
        currentChapter: MangaChapter(
            tid: document.tid,
            rawTitle: document.chapterTitle,
            chapterNumber: MangaTitleCleaner.extractChapterNumber(document.chapterTitle)
        ),
        cleanBookName: "Resolved Directory"
    )
}

private func makeAdjacentPrefetchDocument(tid: String, pageCount: Int) throws -> MangaReaderProjection {
    MangaReaderProjection(
        tid: tid,
        ownerPostID: "post-\(tid)",
        chapterTitle: "第\(tid)话",
        imageURLs: try (0..<pageCount).map { index in
            try XCTUnwrap(URL(string: "https://img.example.com/\(tid)-\(index).jpg"))
        }
    )
}

@MainActor
private func waitForAdjacentPrefetch(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    pollIntervalNanoseconds: UInt64 = 20_000_000,
    predicate: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await predicate() {
            return
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    XCTFail("Timed out waiting for condition")
}

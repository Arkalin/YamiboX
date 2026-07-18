import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class MangaReaderDirectoryPanelTests: XCTestCase {
    func testInitialTagDirectoryRefreshesAfterPrepareAndOffersForcedSearchShortcut() async throws {
        let dateProvider = ManualDateProvider(now: Date(timeIntervalSince1970: 10_000))
        let fixture = try await makeDirectoryPanelFixture(
            seed: MangaDirectorySeed(
                currentChapter: makeChapter(tid: "700", title: "第1话"),
                tagIDs: ["31"],
                cleanBookName: "测试漫画"
            ),
            tagChapters: [makeChapter(tid: "701", title: "第2话")],
            configuration: MangaDirectoryWorkflowConfiguration(now: { dateProvider.now })
        )

        await fixture.model.prepare()

        guard case let .loaded(initialLoaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(initialLoaded.pages.map(\.tid), ["700"])

        try await waitForDirectoryPanelUpdate {
            guard case let .loaded(loaded) = fixture.model.presentation.state else { return false }
            return loaded.directoryPanel.displayChapters.map(\.tid) == ["700", "701"]
        }

        guard case let .loaded(updatedLoaded) = fixture.model.presentation.state else {
            XCTFail("Expected updated loaded presentation")
            return
        }
        XCTAssertEqual(updatedLoaded.directoryPanel.updateButtonTitle, "全局搜索 5s")
        XCTAssertTrue(updatedLoaded.directoryPanel.shouldForceSearchOnUpdate)
        XCTAssertTrue(updatedLoaded.directoryPanel.isSearchMode)
    }

    func testDirectorySortOrderOnlyChangesPanelProjection() async throws {
        let directory = MangaDirectory(
            cleanBookName: "本地目录",
            strategy: .links,
            sourceKey: "本地目录",
            chapters: [
                makeChapter(tid: "700", title: "第1话"),
                makeChapter(tid: "701", title: "第2话")
            ]
        )
        let fixture = try await makeDirectoryPanelFixture(
            directoryName: "本地目录",
            storedDirectories: [directory],
            appSettings: AppSettings(manga: MangaReaderSettings(directorySortOrder: .descending))
        )

        await fixture.model.prepare()

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.directoryPanel.displayChapters.map(\.tid), ["701", "700"])
        XCTAssertEqual(loaded.currentPage?.tid, "700")
        XCTAssertEqual(loaded.readingPosition, MangaReadingPosition(tid: "700", localIndex: 0))
    }

    func testForcedSearchCooldownIsProjectedAsPanelState() async throws {
        let dateProvider = ManualDateProvider(now: Date(timeIntervalSince1970: 20_000))
        let directory = MangaDirectory(
            cleanBookName: "本地目录",
            strategy: .tag,
            sourceKey: "31",
            chapters: [makeChapter(tid: "700", title: "【作者】作品 第1话")]
        )
        let fixture = try await makeDirectoryPanelFixture(
            directoryName: "本地目录",
            storedDirectories: [directory],
            searchChapters: [makeChapter(tid: "702", title: "第3话")],
            configuration: MangaDirectoryWorkflowConfiguration(now: { dateProvider.now })
        )

        await fixture.model.prepare()
        await fixture.model.updateDirectory(isForcedSearch: true)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.directoryPanel.updateButtonTitle, "20s")
        XCTAssertFalse(loaded.directoryPanel.isUpdateButtonEnabled)
        XCTAssertEqual(loaded.directoryPanel.displayChapters.map(\.tid), ["700", "702"])
    }

    func testForcedSearchCancelsDeferredAutomaticTagRefresh() async throws {
        let seed = MangaDirectorySeed(
            currentChapter: makeChapter(tid: "700", title: "第1话"),
            tagIDs: ["31"],
            cleanBookName: "测试漫画"
        )
        let repository = DelayedDirectoryPanelRepository(
            seed: seed,
            tagChapters: [makeChapter(tid: "701", title: "第2话")],
            searchChapters: [makeChapter(tid: "702", title: "第3话")]
        )
        let fixture = try await makeDirectoryPanelFixture(
            seed: seed,
            repository: repository
        )

        await fixture.model.prepare()
        try await waitForDirectoryPanelUpdate {
            await repository.hasStartedTagLoad()
        }
        await fixture.model.updateDirectory(isForcedSearch: true)
        try await Task.sleep(nanoseconds: 350_000_000)

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        let searchRequestCount = await repository.searchRequestCount()
        XCTAssertEqual(searchRequestCount, 1)
        XCTAssertEqual(loaded.directoryPanel.displayChapters.map(\.tid), ["700", "702"])
    }

    func testRenameDirectoryUpdatesPanelWithoutLeavingReaderLoadedState() async throws {
        let directory = MangaDirectory(
            cleanBookName: "旧标题",
            strategy: .searched,
            sourceKey: "旧标题",
            chapters: [makeChapter(tid: "700", title: "第1话")]
        )
        let fixture = try await makeDirectoryPanelFixture(
            directoryName: "旧标题",
            storedDirectories: [directory]
        )

        await fixture.model.prepare()
        await fixture.model.renameDirectory(cleanBookName: " 新标题 ", searchKeyword: " 作者 新标题 ")

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.directoryPanel.directoryTitle, "新标题")
        XCTAssertEqual(loaded.directoryTitle, "新标题")
        XCTAssertNil(loaded.directoryPanel.errorMessage)
    }

    /// Reset must discard the stored "999" chapter (standing in for a stale
    /// or manually-corrected row) and rebuild the directory from a fresh
    /// network seed, while keeping the panel's title stable.
    func testResetDirectoryReseedsFromNetworkDiscardingStaleChapters() async throws {
        let directory = MangaDirectory(
            cleanBookName: "本地目录",
            strategy: .searched,
            sourceKey: "旧来源",
            chapters: [
                makeChapter(tid: "700", title: "第1话"),
                makeChapter(tid: "999", title: "手动新增的章节")
            ]
        )
        let fixture = try await makeDirectoryPanelFixture(
            directoryName: "本地目录",
            seed: MangaDirectorySeed(
                currentChapter: makeChapter(tid: "700", title: "第1话"),
                tagIDs: ["31"],
                cleanBookName: "本地目录"
            ),
            storedDirectories: [directory],
            tagChapters: [makeChapter(tid: "701", title: "第2话")]
        )

        await fixture.model.prepare()
        await fixture.model.resetDirectory()

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.directoryPanel.displayChapters.map(\.tid), ["700", "701"])
        XCTAssertFalse(loaded.directoryPanel.displayChapters.contains(where: { $0.tid == "999" }))
        XCTAssertEqual(loaded.directoryPanel.directoryTitle, "本地目录")
        XCTAssertNil(loaded.directoryPanel.errorMessage)
    }

    func testDirectoryChapterJumpUsesDirectViewportPlacement() async throws {
        let document700 = try makeDocument(tid: "700", pageCount: 1)
        let document701 = try makeDocument(tid: "701", pageCount: 1)
        let directory = MangaDirectory(
            cleanBookName: "本地目录",
            strategy: .links,
            sourceKey: "本地目录",
            chapters: [
                makeChapter(tid: "700", title: "第1话"),
                makeChapter(tid: "701", title: "第2话")
            ]
        )
        let fixture = try await makeDirectoryPanelFixture(
            directoryName: "本地目录",
            document: document700,
            extraDocuments: [document701],
            storedDirectories: [directory]
        )

        await fixture.model.prepare()
        await fixture.model.jumpToChapter(directory.chapters[1])

        guard case let .loaded(loaded) = fixture.model.presentation.state else {
            XCTFail("Expected loaded presentation")
            return
        }
        XCTAssertEqual(loaded.currentPage?.tid, "701")
        XCTAssertEqual(loaded.viewportPlacement?.targetPageIndex, 1)
        XCTAssertEqual(loaded.viewportPlacement?.animated, false)
    }
}

private struct MangaReaderDirectoryPanelFixture {
    let model: MangaReaderViewModel
    let settingsStore: SettingsStore
}

@MainActor
private func makeDirectoryPanelFixture(
    directoryName: String? = nil,
    document: MangaReaderProjection? = nil,
    extraDocuments: [MangaReaderProjection] = [],
    seed: MangaDirectorySeed? = nil,
    repository: (any MangaDirectoryRepository)? = nil,
    storedDirectories: [MangaDirectory] = [],
    tagChapters: [MangaChapter] = [],
    searchChapters: [MangaChapter] = [],
    appSettings: AppSettings = AppSettings(),
    configuration: MangaDirectoryWorkflowConfiguration = MangaDirectoryWorkflowConfiguration()
) async throws -> MangaReaderDirectoryPanelFixture {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-directory-panel")
    let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
    try await settingsStore.save(appSettings)

    let resolvedDocument = try document ?? makeDocument(tid: "700", pageCount: 1)
    let context = MangaLaunchContext(
        originalThreadID: "700",
        chapterTID: resolvedDocument.tid,
        displayTitle: "测试漫画",
        source: .forum,
        directoryName: directoryName
    )
    let resolvedRepository = repository ?? DirectoryPanelRepository(
        seed: seed ?? MangaDirectorySeed(
            currentChapter: makeChapter(tid: resolvedDocument.tid, title: resolvedDocument.chapterTitle),
            cleanBookName: "测试漫画"
        ),
        tagChapters: tagChapters,
        searchChapters: searchChapters
    )
    let documents = Dictionary(
        uniqueKeysWithValues: ([resolvedDocument] + extraDocuments).map { ($0.tid, $0) }
    )
    let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
    #if os(iOS)
    let dependencies = MangaReaderViewModelDependencies(
        settingsStore: settingsStore,
        makeProjectionLoader: { DirectoryPanelProjectionLoader(documents: documents) },
        makeDirectoryRepository: { resolvedRepository },
        makeDirectoryStore: { DirectoryPanelStore(directories: storedDirectories) },
        makeDirectorySearchCooldownState: { MangaDirectorySearchCooldownState() },
        directoryWorkflowConfiguration: configuration,
        progressSync: ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: readingProgressStore
            ),
            debounceNanoseconds: 0
        )
    )
    #else
    let dependencies = MangaReaderViewModelDependencies(
        settingsStore: settingsStore,
        makeProjectionLoader: { DirectoryPanelProjectionLoader(documents: documents) },
        makeDirectoryRepository: { resolvedRepository },
        makeDirectoryStore: { DirectoryPanelStore(directories: storedDirectories) },
        makeDirectorySearchCooldownState: { MangaDirectorySearchCooldownState() },
        directoryWorkflowConfiguration: configuration,
        progressSync: ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(
                    readingProgressStore: readingProgressStore
            ),
            debounceNanoseconds: 0
        )
    )
    #endif
    return MangaReaderDirectoryPanelFixture(
        model: MangaReaderViewModel(context: context, viewModelDependencies: dependencies),
        settingsStore: settingsStore
    )
}

private actor DirectoryPanelProjectionLoader: MangaReaderProjectionLoading {
    private let documents: [String: MangaReaderProjection]

    init(documents: [String: MangaReaderProjection]) {
        self.documents = documents
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        guard let document = documents[request.threadID] else {
            throw YamiboError.unreadableBody
        }
        return document
    }
}

private actor DirectoryPanelRepository: MangaDirectoryRepository {
    private let seed: MangaDirectorySeed
    private let tagChapters: [MangaChapter]
    private let searchChapters: [MangaChapter]

    init(
        seed: MangaDirectorySeed,
        tagChapters: [MangaChapter],
        searchChapters: [MangaChapter]
    ) {
        self.seed = seed
        self.tagChapters = tagChapters
        self.searchChapters = searchChapters
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        seed
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        tagChapters
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        searchChapters
    }
}

private actor DelayedDirectoryPanelRepository: MangaDirectoryRepository {
    private let seed: MangaDirectorySeed
    private let tagChapters: [MangaChapter]
    private let searchChapters: [MangaChapter]
    private var didStartTagLoad = false
    private var searchRequests = 0

    init(
        seed: MangaDirectorySeed,
        tagChapters: [MangaChapter],
        searchChapters: [MangaChapter]
    ) {
        self.seed = seed
        self.tagChapters = tagChapters
        self.searchChapters = searchChapters
    }

    func loadDirectorySeed(for threadID: String) async throws -> MangaDirectorySeed {
        seed
    }

    func loadTagDirectory(tagIDs: [String], allowedForumID: String) async throws -> [MangaChapter] {
        didStartTagLoad = true
        try await Task.sleep(nanoseconds: 200_000_000)
        return tagChapters
    }

    func searchDirectory(keyword: String, forumID: String) async throws -> [MangaChapter] {
        searchRequests += 1
        return searchChapters
    }

    func hasStartedTagLoad() -> Bool {
        didStartTagLoad
    }

    func searchRequestCount() -> Int {
        searchRequests
    }
}

private actor DirectoryPanelStore: MangaDirectoryPersisting {
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

private final class ManualDateProvider: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private func makeChapter(tid: String, title: String) -> MangaChapter {
    MangaChapter(
        tid: tid,
        rawTitle: title,
        chapterNumber: MangaTitleCleaner.extractChapterNumber(title)
    )
}

private func makeDocument(tid: String, pageCount: Int) throws -> MangaReaderProjection {
    MangaReaderProjection(
        tid: tid,
        ownerPostID: "post-\(tid)",
        chapterTitle: "第1话",
        imageURLs: try (0..<pageCount).map { index in
            try XCTUnwrap(URL(string: "https://img.example.com/\(tid)-\(index).jpg"))
        }
    )
}

@MainActor
private func waitForDirectoryPanelUpdate(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    pollIntervalNanoseconds: UInt64 = 20_000_000,
    predicate: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    do {
        try await waitForCondition(
            timeout: .nanoseconds(Int64(timeoutNanoseconds)),
            pollInterval: .nanoseconds(Int64(pollIntervalNanoseconds))
        ) { await predicate() }
    } catch is TestWaitTimeoutError {
        XCTFail("Timed out waiting for condition")
    }
}

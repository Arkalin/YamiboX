import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

/// Covers smart-comic-mode design decision #16 (Phase D "cover mode-gating"):
/// - `MangaReaderViewModel`'s manual cover entry writes `.smartManga` when the
///   board's Smart Comic Mode is on, and the same `.thread(tid:)` key
///   `ImageBrowserCoverActions` uses for a normal thread when it's off — keyed
///   directly off `context.isSmartModeEnabled`, never off whether a
///   directory/cleanBookName happens to be resolvable (the same proxy-signal
///   trap earlier phases' adversarial reviews caught).
/// - Mode off additionally auto-resolves and writes a `.thread(tid:)` cover
///   via `ThreadCoverResolver`, mirroring `ForumThreadReaderViewModel`'s
///   normal-thread behavior; mode on never does this.
@MainActor
final class MangaReaderCoverTests: XCTestCase {
    func testManualCoverWritesThreadKeyWhenSmartModeDisabled() async throws {
        let fixture = try await makeFixture(isSmartModeEnabled: false)

        await fixture.model.prepare()
        let page = try firstPage(of: fixture.model)
        let succeeded = await fixture.model.setMangaCover(page: page)

        XCTAssertTrue(succeeded)
        let threadCover = await fixture.contentCoverStore.cover(for: .thread(tid: "701"))
        XCTAssertNotNil(threadCover?.manualCoverURL)
        let mangaCover = await fixture.contentCoverStore.cover(for: .smartManga(cleanBookName: "测试漫画"))
        XCTAssertNil(mangaCover?.manualCoverURL)
    }

    func testManualCoverWritesSmartMangaKeyWhenSmartModeEnabled() async throws {
        let fixture = try await makeFixture(isSmartModeEnabled: true)

        await fixture.model.prepare()
        let page = try firstPage(of: fixture.model)
        let succeeded = await fixture.model.setMangaCover(page: page)

        XCTAssertTrue(succeeded)
        let mangaCover = await fixture.contentCoverStore.cover(for: .smartManga(cleanBookName: "测试漫画"))
        XCTAssertNotNil(mangaCover?.manualCoverURL)
        let threadCover = await fixture.contentCoverStore.cover(for: .thread(tid: "701"))
        XCTAssertNil(threadCover?.manualCoverURL)
    }

    func testCanSetMangaCoverIsTrueWhenSmartModeDisabledEvenBeforeDirectoryResolves() async throws {
        // Mode off never resolves a real directory (decision #12) — the
        // cover entry must not depend on `workflow?.currentDirectoryCleanBookName()`
        // being non-nil, only on `context.isSmartModeEnabled`.
        let fixture = try await makeFixture(isSmartModeEnabled: false)

        XCTAssertTrue(fixture.model.canSetMangaCover)
    }

    func testAutoThreadCoverResolutionWritesThreadCoverWhenSmartModeDisabled() async throws {
        let coverCandidateURL = try XCTUnwrap(URL(string: "https://img.example.com/auto-cover.jpg"))
        let fixture = try await makeFixture(
            isSmartModeEnabled: false,
            threadCoverPageRepository: CoverTestThreadCoverPageRepository(
                page: coverTestThreadPage(tid: "701", imageURLString: coverCandidateURL.absoluteString)
            )
        )

        await fixture.model.prepare()

        try await waitFor {
            await fixture.contentCoverStore.cover(for: .thread(tid: "701"))?.automaticCoverURL != nil
        }
        let threadCover = await fixture.contentCoverStore.cover(for: .thread(tid: "701"))
        XCTAssertEqual(threadCover?.automaticCoverURL, coverCandidateURL)
    }

    func testAutoThreadCoverResolutionDoesNotRunWhenSmartModeEnabled() async throws {
        let coverCandidateURL = try XCTUnwrap(URL(string: "https://img.example.com/auto-cover.jpg"))
        let fixture = try await makeFixture(
            isSmartModeEnabled: true,
            threadCoverPageRepository: CoverTestThreadCoverPageRepository(
                page: coverTestThreadPage(tid: "701", imageURLString: coverCandidateURL.absoluteString)
            )
        )

        await fixture.model.prepare()
        // No task is scheduled at all when mode is on, so there is nothing to
        // await; a short grace period is enough to catch a regression that
        // fires the resolution unconditionally.
        try await Task.sleep(nanoseconds: 150_000_000)

        let threadCover = await fixture.contentCoverStore.cover(for: .thread(tid: "701"))
        XCTAssertNil(threadCover?.automaticCoverURL)
    }
}

@MainActor
private func firstPage(of model: MangaReaderViewModel) throws -> MangaReaderPageProjection {
    guard case let .loaded(loaded) = model.presentation.state, let page = loaded.pages.first else {
        throw XCTSkip("Expected a loaded manga reader presentation with at least one page")
    }
    return page
}

private struct MangaReaderCoverFixture {
    let model: MangaReaderViewModel
    let contentCoverStore: ContentCoverStore
}

@MainActor
private func makeFixture(
    isSmartModeEnabled: Bool,
    threadCoverPageRepository: (any ThreadCoverPageResolving)? = nil
) async throws -> MangaReaderCoverFixture {
    let defaultsSuiteName = YamiboTestDefaults.suiteName(prefix: "manga-cover-fixture")
    let settingsStore = try SettingsStore(testSuiteName: defaultsSuiteName, key: "settings")
    try await settingsStore.save(AppSettings())

    let context = MangaLaunchContext(
        originalThreadID: "700",
        chapterTID: "701",
        displayTitle: "测试漫画",
        source: .forum,
        initialPage: 0,
        directoryName: nil,
        isSmartModeEnabled: isSmartModeEnabled
    )
    let document = MangaReaderProjection(
        tid: "701",
        ownerPostID: "post-701",
        chapterTitle: "测试漫画",
        imageURLs: [try XCTUnwrap(URL(string: "https://img.example.com/701-0.jpg"))]
    )
    let repository = CoverTestMangaDirectoryRepository(
        seed: MangaDirectorySeed(
            currentChapter: MangaChapter(tid: "701", rawTitle: "测试漫画", chapterNumber: 1),
            cleanBookName: "测试漫画",
            firstPostID: "post-701"
        )
    )
    let readingProgressStore = try ReadingProgressStore(testSuiteName: defaultsSuiteName, key: "reading-progress")
    let contentCoverStore = ContentCoverStore(
        defaults: try YamiboTestDefaults.defaults(suiteName: defaultsSuiteName),
        key: "content-covers"
    )
    let dependencies = MangaReaderViewModelDependencies(
        settingsStore: settingsStore,
        makeProjectionLoader: { CoverTestMangaReaderProjectionLoader(documents: [document]) },
        makeDirectoryRepository: { repository },
        makeDirectoryStore: { CoverTestMangaDirectoryStore() },
        makeContentCoverStore: { contentCoverStore },
        makeThreadCoverPageRepository: { threadCoverPageRepository },
        progressSync: ProgressSyncModule(
            adapter: FavoriteLibraryProgressSyncAdapter(readingProgressStore: readingProgressStore),
            debounceNanoseconds: 0
        )
    )
    let model = MangaReaderViewModel(context: context, viewModelDependencies: dependencies)
    return MangaReaderCoverFixture(model: model, contentCoverStore: contentCoverStore)
}

private func coverTestThreadPage(tid: String, imageURLString: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "测试漫画",
        posts: [
            ForumThreadPost(
                postID: "\(tid)-1",
                floorText: "1#",
                author: BlogReaderUser(uid: "9", name: "owner"),
                contentHTML: "",
                contentText: "",
                images: [ForumThreadPostImage(url: imageURLString)]
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 1)
    )
}

private actor CoverTestThreadCoverPageRepository: ThreadCoverPageResolving {
    private let page: ForumThreadPage

    init(page: ForumThreadPage) {
        self.page = page
    }

    func cachedThreadPage(thread _: ThreadIdentity, title _: String, authorID _: String?, page _: Int) async -> ForumThreadPage? {
        nil
    }

    func fetchThreadPage(thread _: ThreadIdentity, title _: String, authorID _: String?, page pageNumber: Int) async throws -> ForumThreadPage {
        page
    }
}

private actor CoverTestMangaReaderProjectionLoader: MangaReaderProjectionLoading {
    let documents: [String: MangaReaderProjection]

    init(documents: [MangaReaderProjection]) {
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.tid, $0) })
    }

    func loadReaderProjection(_ request: MangaReaderProjectionRequest) async throws -> MangaReaderProjection {
        guard let document = documents[request.threadID] else {
            throw YamiboError.unreadableBody
        }
        return document
    }
}

private actor CoverTestMangaDirectoryRepository: MangaDirectoryRepository {
    let seed: MangaDirectorySeed

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

private actor CoverTestMangaDirectoryStore: MangaDirectoryPersisting {
    private var directories: [String: MangaDirectory] = [:]

    func directory(named name: String) async throws -> MangaDirectory? {
        directories[name]
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        directories.values.first { $0.chapters.contains { $0.tid == tid } }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {
        directories[directory.cleanBookName] = directory
    }

    func deleteDirectory(named name: String) async throws {
        directories.removeValue(forKey: name)
    }
}

@MainActor
private func waitFor(
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

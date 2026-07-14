import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
@Test func forumThreadReaderLoadsExistingLocalFavoriteState() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    var document = FavoriteLibraryDocument()
    document.upsertItem(try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "704"),
        title: "已收藏标题",
        locations: [.category(document.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(document)
    let model = fixture.makeModel()

    await model.load()

    #expect(model.isFavorited)
}

@MainActor
@Test func forumThreadReaderTogglesRemoteFavoriteAndSyncsLocalState() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()

    await model.load()
    #expect(!model.isFavorited)

    // Default settings ask about the Yamibo push before adding.
    await model.toggleFavorite()
    #expect(model.favoriteAddPromptPresented)
    await model.confirmFavoriteAdd(syncToRemote: true, remember: false)

    let added = try #require(await fixture.localFavoriteItem())
    #expect(model.isFavorited)
    #expect(added.title == "解析标题")
    #expect(added.remoteMapping?.yamiboFavoriteID == "8801")
    #expect(added.forumID == "40")
    #expect(added.forumName == "综合讨论")
    #expect(added.sourceGroup == .forumBoard(id: "40", label: "综合讨论"))
    #expect(added.contentUpdatedAt == FavoriteContentUpdateDateResolver.date(
        lastEditedText: "本帖最后由 楼主 于 2026-6-2 12:00 编辑",
        postedAtText: "2026-6-1 10:00"
    ))
    #expect(await fixture.favoriteRepository.addedThreadIDs == ["704"])

    // Removing a mapped favorite asks about the remote delete.
    await model.toggleFavorite()
    let removePrompt = try #require(model.favoriteRemovePrompt)
    await model.confirmFavoriteRemoval(removePrompt.favorite, removeRemote: true, remember: false)

    #expect(!model.isFavorited)
    #expect(await fixture.localFavoriteItem() == nil)
    #expect(await fixture.favoriteRepository.deletedRemoteFavoriteIDs == ["8801"])
}

@MainActor
@Test func forumThreadReaderLocalOnlyAddSkipsRemotePushAndRemovesWithoutPrompt() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()

    await model.load()
    await model.toggleFavorite()
    #expect(model.favoriteAddPromptPresented)
    await model.confirmFavoriteAdd(syncToRemote: false, remember: false)

    let added = try #require(await fixture.localFavoriteItem())
    #expect(model.isFavorited)
    #expect(added.remoteMapping?.yamiboFavoriteID == nil)
    #expect(await fixture.favoriteRepository.addedThreadIDs.isEmpty)

    // Unmapped favorites delete locally without the remote question.
    await model.toggleFavorite()
    #expect(model.favoriteRemovePrompt == nil)
    #expect(!model.isFavorited)
    #expect(await fixture.localFavoriteItem() == nil)
    #expect(await fixture.favoriteRepository.deletedRemoteFavoriteIDs.isEmpty)
}

@MainActor
@Test func forumThreadReaderRememberedAddChoiceSkipsPrompt() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()

    await model.load()
    await model.toggleFavorite()
    #expect(model.favoriteAddPromptPresented)
    await model.confirmFavoriteAdd(syncToRemote: true, remember: true)
    let settings = await fixture.settingsStore.load().favorites
    #expect(!settings.addSyncPromptEnabled)
    #expect(settings.addSyncDefault)

    // Remove (prompted), then add again: the remembered choice syncs silently.
    await model.toggleFavorite()
    let removePrompt = try #require(model.favoriteRemovePrompt)
    await model.confirmFavoriteRemoval(removePrompt.favorite, removeRemote: false, remember: false)

    await model.toggleFavorite()
    #expect(!model.favoriteAddPromptPresented)
    #expect(model.isFavorited)
    #expect(await fixture.favoriteRepository.addedThreadIDs == ["704", "704"])
}

@MainActor
@Test func forumThreadReaderToggleBeforePageLoadUsesContextForumID() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()

    await model.toggleFavorite()
    #expect(model.favoriteAddPromptPresented)
    await model.confirmFavoriteAdd(syncToRemote: false, remember: false)

    let added = try #require(await fixture.localFavoriteItem())
    #expect(added.title == "上下文标题")
    #expect(added.forumID == "40")
    #expect(added.sourceGroup == .forumBoard(id: "40", label: "40"))
}

/// Smart-comic-mode decision #4: star-button classification is by board fid
/// alone, independent of Smart Comic Mode's on/off state (fid 30 is on by
/// default, but that's incidental here — the point is the board is a manga
/// board at all). Also covers the add/remove consistency fix: removing must
/// find the same `.mangaThread` target that was actually persisted, not a
/// `.normalThread` one re-derived from `Favorite` alone.
@MainActor
@Test func forumThreadReaderClassifiesMangaBoardFavoriteAsMangaThreadAndRemovesConsistently() async throws {
    let fixture = try ForumThreadReaderViewModelFixture(fid: "30")
    let model = fixture.makeModel()

    // Deliberately not calling `model.load()`: the fake page loader's
    // fetched page always reports forumID "40" (see `makeThreadPage`), which
    // would clobber the manga-board fid this test is about. Toggling before
    // any page loads falls back to `context.thread.fid`, exactly like
    // `forumThreadReaderToggleBeforePageLoadUsesContextForumID` above.
    await model.toggleFavorite()
    #expect(model.favoriteAddPromptPresented)
    await model.confirmFavoriteAdd(syncToRemote: false, remember: false)

    let added = try #require(await fixture.localFavoriteItem())
    #expect(added.target == .mangaThread(threadID: "704"))
    #expect(added.target.id == "manga-thread:704")
    #expect(model.isFavorited)

    // Toggling off must remove this exact `.mangaThread` item, not silently
    // no-op by re-deriving a `.normalThread` target at remove time.
    await model.toggleFavorite()
    #expect(model.favoriteRemovePrompt == nil)
    #expect(!model.isFavorited)
    #expect(await fixture.localFavoriteItem() == nil)
}

/// Smart-comic-mode decision #8's local half: the star-button add path shows
/// immediate feedback when the newly favorited chapter shares a
/// `MangaDirectory` with an already-favorited sibling.
@MainActor
@Test func forumThreadReaderShowsAutoAttributionToastWhenSiblingChapterAlreadyFavorited() async throws {
    let directory = MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .links,
        sourceKey: "测试漫画",
        chapters: [
            MangaChapter(tid: "700", rawTitle: "第一话", chapterNumber: 1),
            MangaChapter(tid: "704", rawTitle: "第二话", chapterNumber: 2)
        ]
    )
    let fixture = try ForumThreadReaderViewModelFixture(
        fid: "30",
        mangaDirectoryStore: ForumThreadReaderTestMangaDirectoryStore(directories: [directory])
    )
    var seedDocument = try await fixture.localFavoriteLibraryStore.load()
    // The sibling must carry its own board fid: the toast's second gate
    // re-checks isSmartComicModeEnabled(forumID:) per sibling (mirroring the
    // Favorites page's per-member merge rule), and a missing fid reads as
    // smart-off under the strict one-rule semantics.
    seedDocument.upsertItem(try FavoriteItem(
        target: .mangaThread(threadID: "700"),
        title: "第一话",
        sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
        locations: [.category(seedDocument.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(seedDocument)
    let model = fixture.makeModel()

    // Not calling `model.load()` — see the comment in the classification
    // test above for why.
    await model.toggleFavorite()
    #expect(model.favoriteAddPromptPresented)
    await model.confirmFavoriteAdd(syncToRemote: false, remember: false)

    #expect(model.transientMessage == L10n.string(
        "favorites.quick.auto_attributed",
        L10n.string("favorites.quick.added_local"),
        "测试漫画"
    ))
}

/// Decision #8 fires only when the board's Smart Comic Mode is actually on
/// (an explicit settings lookup) — a directory resolving and a sibling
/// favorite existing must not be enough by themselves.
@MainActor
@Test func forumThreadReaderSkipsAutoAttributionToastWhenSmartComicModeIsOff() async throws {
    let directory = MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .links,
        sourceKey: "测试漫画",
        chapters: [
            MangaChapter(tid: "700", rawTitle: "第一话", chapterNumber: 1),
            MangaChapter(tid: "704", rawTitle: "第二话", chapterNumber: 2)
        ]
    )
    let fixture = try ForumThreadReaderViewModelFixture(
        fid: "30",
        mangaDirectoryStore: ForumThreadReaderTestMangaDirectoryStore(directories: [directory])
    )
    var settings = await fixture.settingsStore.load()
    settings.boardReader.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "30")
    try await fixture.settingsStore.save(settings)
    var seedDocument = try await fixture.localFavoriteLibraryStore.load()
    seedDocument.upsertItem(try FavoriteItem(
        target: .mangaThread(threadID: "700"),
        title: "第一话",
        locations: [.category(seedDocument.defaultCategory.id)]
    ))
    try await fixture.localFavoriteLibraryStore.save(seedDocument)
    let model = fixture.makeModel()

    // Not calling `model.load()` — see the comment in the classification
    // test above for why.
    await model.toggleFavorite()
    #expect(model.favoriteAddPromptPresented)
    await model.confirmFavoriteAdd(syncToRemote: false, remember: false)

    #expect(model.transientMessage == L10n.string("favorites.quick.added_local"))
}

@MainActor
@Test func forumThreadReaderLoadUsesCachedPageWithoutFetching() async throws {
    let cachedPage = ForumThreadPage(
        thread: ThreadIdentity(tid: "704"),
        title: "缓存标题",
        posts: [
            ForumThreadPost(
                postID: "cached",
                author: BlogReaderUser(uid: "42", name: "楼主"),
                contentHTML: "",
                contentText: "缓存正文"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 4)
    )
    let fixture = try ForumThreadReaderViewModelFixture(cachedPages: [1: cachedPage])
    let model = fixture.makeModel()

    await model.load()

    #expect(model.page?.title == "缓存标题")
    #expect(fixture.repository.cachedPageCalls() == [1])
    #expect(fixture.repository.fetchPageCalls().isEmpty)
}

@MainActor
@Test func forumThreadReaderRefreshBypassesCachedPageAndFetches() async throws {
    let cachedPage = ForumThreadPage(
        thread: ThreadIdentity(tid: "704"),
        title: "缓存标题",
        posts: [
            ForumThreadPost(
                postID: "cached",
                author: BlogReaderUser(uid: "42", name: "楼主"),
                contentHTML: "",
                contentText: "缓存正文"
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: 1, totalPages: 4)
    )
    let fixture = try ForumThreadReaderViewModelFixture(cachedPages: [1: cachedPage])
    let model = fixture.makeModel()

    await model.load()
    await model.refresh()

    #expect(model.page?.title == "解析标题")
    #expect(fixture.repository.cachedPageCalls() == [1])
    #expect(fixture.repository.fetchPageCalls() == [1])
}

@MainActor
@Test func forumThreadReaderRefreshFailurePreservesExistingPageAndShowsTransientMessage() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()

    await model.load()
    fixture.repository.fetchError = ForumThreadReaderTestError.plannedFailure
    await model.refresh()

    #expect(model.page?.title == "解析标题")
    #expect(model.errorMessage == nil)
    #expect(model.transientMessage == L10n.string("forum.thread.refresh_failed", ForumThreadReaderTestError.plannedFailure.localizedDescription))
    #expect(fixture.repository.cachedPageCalls() == [1, 1])
    #expect(fixture.repository.fetchPageCalls() == [1, 1])
}

@MainActor
@Test func forumThreadReaderRefreshFailureFallsBackToCachedPage() async throws {
    let cachedPage = makeThreadPage(title: "缓存标题", postID: "cached", contentText: "缓存正文")
    let fixture = try ForumThreadReaderViewModelFixture(cachedPages: [1: cachedPage], fetchError: ForumThreadReaderTestError.plannedFailure)
    let model = fixture.makeModel()

    await model.load()
    await model.refresh()

    #expect(model.page?.title == "缓存标题")
    #expect(model.errorMessage == nil)
    #expect(model.transientMessage == L10n.string("forum.thread.refresh_failed", ForumThreadReaderTestError.plannedFailure.localizedDescription))
    #expect(fixture.repository.cachedPageCalls() == [1, 1])
    #expect(fixture.repository.fetchPageCalls() == [1])
}

/// generation-guard coverage: a slow `goToPage(2)` response landing after a
/// faster, later `goToPage(3)` must be discarded rather than clobbering the
/// already-displayed page 3 content back to page 2.
@MainActor
@Test func forumThreadReaderStaleGoToPageResponseDoesNotOverwriteNewerPage() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()
    await model.load()

    fixture.repository.gatedPages = [2]
    let staleTask = Task { await model.goToPage(2) }
    await fixture.repository.gate.waitUntilBlocked()

    await model.goToPage(3)
    #expect(model.currentPage == 3)
    #expect(model.page?.pageNavigation?.currentPage == 3)

    await fixture.repository.gate.release()
    await staleTask.value

    #expect(model.currentPage == 3)
    #expect(model.page?.pageNavigation?.currentPage == 3)
    #expect(model.errorMessage == nil)
}

/// generation-guard coverage for the failure fall-through branches: a stale
/// refresh failure that resumes (inside its catch block's cache-fallback
/// lookup) only after a newer page has already rendered must be discarded
/// entirely — no stale failure toast over the newer page.
@MainActor
@Test func forumThreadReaderStaleRefreshFailureDoesNotShowStaleToastOverNewerPage() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()
    await model.load()

    fixture.repository.fetchError = ForumThreadReaderTestError.plannedFailure
    fixture.repository.gatedCachedPages = [1]
    let staleTask = Task { await model.refresh() }
    await fixture.repository.gate.waitUntilBlocked()

    fixture.repository.fetchError = nil
    await model.goToPage(3)
    #expect(model.currentPage == 3)
    #expect(model.transientMessage == nil)

    await fixture.repository.gate.release()
    await staleTask.value

    #expect(model.currentPage == 3)
    #expect(model.page?.pageNavigation?.currentPage == 3)
    #expect(model.transientMessage == nil)
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)
}

/// The failure fall-through's page-clearing branch is guarded the same way:
/// a stale refresh failure resuming after a newer request already recorded
/// its own failure must not rewrite `currentPage` back to the stale
/// request's page.
@MainActor
@Test func forumThreadReaderStaleRefreshFailureDoesNotClobberNewerFailureState() async throws {
    let fixture = try ForumThreadReaderViewModelFixture(fetchError: ForumThreadReaderTestError.plannedFailure)
    let model = fixture.makeModel()
    await model.load()
    #expect(model.page == nil)
    #expect(model.currentPage == 1)

    fixture.repository.gatedCachedPages = [1]
    let staleTask = Task { await model.refresh() }
    await fixture.repository.gate.waitUntilBlocked()

    await model.goToPage(3)
    #expect(model.currentPage == 3)

    await fixture.repository.gate.release()
    await staleTask.value

    #expect(model.currentPage == 3)
    #expect(model.page == nil)
    #expect(model.errorMessage == ForumThreadReaderTestError.plannedFailure.localizedDescription)
    #expect(!model.isLoading)
}

@MainActor
@Test func forumThreadReaderInitialLoadFailureWithoutCacheUsesPageError() async throws {
    let fixture = try ForumThreadReaderViewModelFixture(fetchError: ForumThreadReaderTestError.plannedFailure)
    let model = fixture.makeModel()

    await model.load()

    #expect(model.page == nil)
    #expect(model.errorMessage == ForumThreadReaderTestError.plannedFailure.localizedDescription)
    #expect(model.transientMessage == nil)
    #expect(fixture.repository.cachedPageCalls() == [1])
    #expect(fixture.repository.fetchPageCalls() == [1])
}

@MainActor
@Test func forumThreadReaderVotePollWithoutLoadedPageThrowsLoginInfoError() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()

    await #expect(throws: YamiboError.underlying(L10n.string("forum.thread.login_info_failed"))) {
        try await model.votePoll(optionIDs: ["1"])
    }
    #expect(fixture.repository.votePollCalls().isEmpty)
}

@MainActor
@Test func forumThreadReaderVotePollUsesPageForumIDAndFormHashThenRefreshes() async throws {
    let fixture = try ForumThreadReaderViewModelFixture(formHash: " hash-1 ")
    let model = fixture.makeModel()

    await model.load()
    let message = try await model.votePoll(optionIDs: ["2", "5"])

    #expect(message == "投票成功")
    #expect(fixture.repository.votePollCalls() == ["40|704|2,5|hash-1"])
    #expect(fixture.repository.fetchPageCalls() == [1, 1])
}

@MainActor
@Test func forumThreadReaderRatePostWithoutFormHashThrowsLoginInfoError() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()

    await model.load()

    await #expect(throws: YamiboError.underlying(L10n.string("forum.thread.login_info_failed"))) {
        try await model.ratePost(postID: "4001", score: 2, reason: "赞", noticeAuthor: true)
    }
    #expect(fixture.repository.ratePostCalls().isEmpty)
}

@MainActor
@Test func forumThreadReaderCommentPostUsesFormHashAndCurrentPage() async throws {
    let fixture = try ForumThreadReaderViewModelFixture(formHash: "hash-2")
    let model = fixture.makeModel()

    await model.load()
    _ = try await model.commentPost(postID: "4001", message: "评论内容")

    #expect(fixture.repository.commentPostCalls() == ["704|4001|评论内容|hash-2|1"])
}

@MainActor
@Test func forumThreadReaderImageBrowserRequestCollectsPageImagesAroundTappedImage() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()
    let firstURL = try #require(URL(string: "https://img.example.com/first.jpg"))
    let secondURL = try #require(URL(string: "https://img.example.com/second.jpg"))
    let refererURL = try #require(URL(string: "https://bbs.yamibo.com/thread-704-1-1.html"))
    model.page = ForumThreadPage(
        thread: ThreadIdentity(tid: "704"),
        title: "标题",
        posts: [
            ForumThreadPost(
                postID: "4001",
                author: BlogReaderUser(uid: "42", name: "楼主"),
                contentHTML: "",
                contentText: "",
                contentBlocks: [
                    ForumThreadContentBlock(id: "first", kind: .image(ForumThreadImageBlock(url: firstURL))),
                    ForumThreadContentBlock(id: "second", kind: .image(ForumThreadImageBlock(url: secondURL, altText: "第二张")))
                ]
            )
        ]
    )

    let request = try #require(model.imageBrowserRequest(
        imageID: "second",
        url: secondURL,
        title: "第二张",
        refererURL: refererURL
    ))

    #expect(request.items.map(\.id) == ["first", "second"])
    #expect(request.initialItemID == "second")
    #expect(request.items.allSatisfy { $0.source.refererPageURL == refererURL })
}

@MainActor
@Test func forumThreadReaderImageBrowserRequestFallsBackToTappedImageWhenPageHasNoGalleryImages() async throws {
    let fixture = try ForumThreadReaderViewModelFixture()
    let model = fixture.makeModel()
    let tappedURL = try #require(URL(string: "https://img.example.com/only.jpg"))
    let refererURL = try #require(URL(string: "https://bbs.yamibo.com/thread-704-1-1.html"))

    #expect(model.imageBrowserRequest(imageID: "only", url: tappedURL, title: nil, refererURL: refererURL) == nil)

    model.page = makeThreadPage(title: "标题", postID: "4001", contentText: "纯文本")
    let request = try #require(model.imageBrowserRequest(
        imageID: "only",
        url: tappedURL,
        title: "  ",
        refererURL: refererURL
    ))

    #expect(request.items.map(\.id) == ["only"])
    #expect(request.initialItemID == "only")
    #expect(request.items.first?.title == L10n.string("forum.thread.image"))
    #expect(request.items.first?.source == YamiboImageSource(url: tappedURL, refererPageURL: refererURL))
}

private enum ForumThreadReaderTestError: LocalizedError {
    case plannedFailure

    var errorDescription: String? {
        "planned failure"
    }
}

private func makeThreadPage(
    title: String,
    postID: String,
    contentText: String,
    page: Int = 1,
    formHash: String? = nil
) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: "704"),
        title: title,
        posts: [
            ForumThreadPost(
                postID: postID,
                author: BlogReaderUser(uid: "42", name: "楼主"),
                postedAtText: "2026-6-1 10:00",
                lastEditedText: "本帖最后由 楼主 于 2026-6-2 12:00 编辑",
                contentHTML: "",
                contentText: contentText
            )
        ],
        pageNavigation: ForumPageNavigation(currentPage: page, totalPages: 4),
        forumID: "40",
        forumName: "综合讨论",
        formHash: formHash
    )
}

private struct ForumThreadReaderViewModelFixture {
    let suiteName: String
    let threadURL: URL
    let localFavoriteLibraryStore: FavoriteLibraryStore
    let settingsStore: SettingsStore
    let repository: FakeForumThreadPageLoader
    let favoriteRepository: FakeThreadFavoriteRepository
    let fid: String
    let mangaDirectoryStore: (any MangaDirectoryPersisting)?

    init(
        cachedPages: [Int: ForumThreadPage] = [:],
        fetchError: Error? = nil,
        formHash: String? = nil,
        fid: String = "40",
        mangaDirectoryStore: (any MangaDirectoryPersisting)? = nil
    ) throws {
        suiteName = "ForumThreadReaderViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        threadURL = try #require(URL(string: "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=704&mobile=2"))
        localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try #require(UserDefaults(suiteName: suiteName)),
            key: "local-favorites"
        )
        settingsStore = SettingsStore(
            defaults: try #require(UserDefaults(suiteName: suiteName)),
            key: "settings"
        )
        repository = FakeForumThreadPageLoader(
            threadURL: threadURL,
            cachedPages: cachedPages,
            fetchError: fetchError,
            formHash: formHash
        )
        favoriteRepository = FakeThreadFavoriteRepository(threadURL: threadURL)
        self.fid = fid
        self.mangaDirectoryStore = mangaDirectoryStore
    }

    func localFavoriteItem() async -> FavoriteItem? {
        (try? await localFavoriteLibraryStore.load())?.items.first { item in
            item.target.threadID == "704"
        }
    }

    @MainActor
    func makeModel() -> ForumThreadReaderViewModel {
        ForumThreadReaderViewModel(
            context: ThreadNovelLaunchContext(
                thread: ThreadIdentity(tid: "704", fid: fid),
                title: "上下文标题"
            ),
            repository: repository,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            favoriteRepository: favoriteRepository,
            mangaDirectoryStore: mangaDirectoryStore,
            settingsStore: settingsStore
        )
    }
}

/// Blocks a gated `fetchThreadPage` call until `release()` is invoked —
/// lets tests deterministically hold a "slow" response in flight past a
/// faster later response without relying on wall-clock sleeps.
private actor ForumThreadPageFetchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isBlocking = false
    private var released = false

    func waitIfNeeded() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isBlocking = true
        }
    }

    func waitUntilBlocked() async {
        while !isBlocking {
            await Task.yield()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class FakeForumThreadPageLoader: ForumThreadPageLoading, @unchecked Sendable {
    let threadURL: URL
    let gate = ForumThreadPageFetchGate()
    var gatedPages: Set<Int> = []
    /// Gates the `cachedThreadPage` lookup instead of the fetch — that
    /// lookup is the suspension point inside `loadPage`'s catch block, so
    /// gating it holds a failure response mid-catch while a newer request
    /// lands.
    var gatedCachedPages: Set<Int> = []
    private let cachedPages: [Int: ForumThreadPage]
    private let formHash: String?
    var fetchError: Error?
    private var recordedCachedPages: [Int] = []
    private var recordedFetchPages: [Int] = []
    private var recordedVotePolls: [String] = []
    private var recordedRatePosts: [String] = []
    private var recordedCommentPosts: [String] = []

    init(
        threadURL: URL,
        cachedPages: [Int: ForumThreadPage] = [:],
        fetchError: Error? = nil,
        formHash: String? = nil
    ) {
        self.threadURL = threadURL
        self.cachedPages = cachedPages
        self.fetchError = fetchError
        self.formHash = formHash
    }

    func cachedThreadPage(context _: ThreadNovelLaunchContext, page: Int) async -> ForumThreadPage? {
        recordedCachedPages.append(page)
        if gatedCachedPages.contains(page) {
            await gate.waitIfNeeded()
        }
        return cachedPages[page]
    }

    func fetchThreadPage(context: ThreadNovelLaunchContext, page: Int) async throws -> ForumThreadPage {
        recordedFetchPages.append(page)
        if gatedPages.contains(page) {
            await gate.waitIfNeeded()
        }
        if let fetchError {
            throw fetchError
        }
        return makeThreadPage(title: "解析标题", postID: "4001", contentText: "正文", page: page, formHash: formHash)
    }

    func cachedPageCalls() -> [Int] {
        recordedCachedPages
    }

    func fetchPageCalls() -> [Int] {
        recordedFetchPages
    }

    func votePollCalls() -> [String] {
        recordedVotePolls
    }

    func ratePostCalls() -> [String] {
        recordedRatePosts
    }

    func commentPostCalls() -> [String] {
        recordedCommentPosts
    }

    func fetchRatingResults(threadID: String, postID: String) async throws -> ForumThreadRatingResultsPage {
        ForumThreadRatingResultsPage(ratings: [])
    }

    func fetchRateOptions(threadID: String, postID: String) async throws -> ForumThreadRateOptionsPage {
        ForumThreadRateOptionsPage(availableScores: [], defaultReasons: [])
    }

    func fetchPollVoters(threadID: String, optionID: String?, page: Int) async throws -> ForumThreadPollVotersPage {
        ForumThreadPollVotersPage(threadID: threadID, selectedOptionID: optionID, pollOptions: [], voters: [])
    }

    func votePoll(forumID: String, threadID: String, optionIDs: [String], formHash: String) async throws -> String {
        recordedVotePolls.append("\(forumID)|\(threadID)|\(optionIDs.joined(separator: ","))|\(formHash)")
        return "投票成功"
    }

    func ratePost(
        threadID: String,
        postID: String,
        score: Int,
        reason: String,
        formHash: String,
        noticeAuthor: Bool
    ) async throws -> String {
        recordedRatePosts.append("\(threadID)|\(postID)|\(score)|\(reason)|\(formHash)|\(noticeAuthor)")
        return ""
    }

    func commentPost(threadID: String, postID: String, message: String, formHash: String, page: Int) async throws -> String {
        recordedCommentPosts.append("\(threadID)|\(postID)|\(message)|\(formHash)|\(page)")
        return ""
    }
}

private actor FakeThreadFavoriteRepository: ForumThreadFavoriteRemoteOperating {
    let threadID: String
    var addedThreadIDs: [String] = []
    var deletedRemoteFavoriteIDs: [String] = []

    init(threadURL: URL) {
        self.threadID = YamiboThreadURLCanonicalizer.threadID(from: threadURL) ?? "704"
    }

    func addThreadFavorite(threadID: String, formHash: String?, resolveRemoteFavorite: Bool) async throws -> Favorite? {
        addedThreadIDs.append(threadID)
        return Favorite(title: "远端标题", threadID: threadID, remoteFavoriteID: "8801")
    }

    func deleteFavorite(remoteFavoriteID: String) async throws {
        deletedRemoteFavoriteIDs.append(remoteFavoriteID)
    }

    func remoteFavorite(forThreadID threadID: String, maxPages: Int) async throws -> Favorite? {
        Favorite(title: "远端标题", threadID: threadID, remoteFavoriteID: "8801")
    }
}

private actor ForumThreadReaderTestMangaDirectoryStore: MangaDirectoryPersisting {
    private let directories: [MangaDirectory]

    init(directories: [MangaDirectory]) {
        self.directories = directories
    }

    func directory(named name: String) async throws -> MangaDirectory? {
        directories.first { $0.cleanBookName == name }
    }

    func directory(containingTID tid: String) async throws -> MangaDirectory? {
        directories.first { directory in
            directory.chapters.contains { $0.tid == tid }
        }
    }

    func saveDirectory(_ directory: MangaDirectory) async throws {}

    func deleteDirectory(named name: String) async throws {}
}

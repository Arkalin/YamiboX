import XCTest
@testable import YamiboXCore
import YamiboXTestSupport

// Shared fixture and seed helpers for the per-page system settings view
// model suites. Split out of the former monolithic
// `SystemSettingsViewModelTests` so every page suite exercises the same
// real-store wiring (one `YamiboAppContext` over one GRDB pool) without
// duplicating this setup.

struct SystemSettingsFixture {
    let appContext: YamiboAppContext
    let settingsStore: SettingsStore
    let novelReaderCacheStore: NovelReaderProjectionStore
    let favoriteBackgroundImageStore: FavoriteBackgroundImageStore
    let mangaDirectoryStore: MangaDirectoryStore
    let mangaReaderProjectionStore: MangaReaderProjectionStore
    let forumCacheStore: ForumCacheStore
    let offlineCacheStore: any TestOfflineCacheStoring
    let ordinaryImageCache: RecordingOrdinaryImageCache
}

func makeSystemSettingsFixture() throws -> SystemSettingsFixture {
    let suiteName = "system-settings-view-model-\(UUID().uuidString)"
    try makeDefaults(suiteName: suiteName).removePersistentDomain(forName: suiteName)

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("system-settings-view-model-\(UUID().uuidString)", isDirectory: true)
    let settingsStore = SettingsStore(defaults: try makeDefaults(suiteName: suiteName), key: "settings")
    let database = try YamiboDatabase.openPool(rootDirectory: root.appendingPathComponent("grdb", isDirectory: true))
    let novelReaderCacheStore = NovelReaderProjectionStore(
        databasePool: database,
        baseDirectory: root.appendingPathComponent("reader-cache", isDirectory: true)
    )
    let favoriteBackgroundImageStore = FavoriteBackgroundImageStore(
        baseDirectory: root.appendingPathComponent("favorite-background", isDirectory: true)
    )
    let mangaDirectoryStore = MangaDirectoryStore(databasePool: database)
    let mangaReaderProjectionStore = MangaReaderProjectionStore(databasePool: database)
    let forumCacheStore = ForumCacheStore(
        databasePool: database,
        baseDirectory: root.appendingPathComponent("forum-cache", isDirectory: true)
    )
    let offlineCacheStore = OfflineCacheStore(
        databasePool: database,
        baseDirectory: root.appendingPathComponent("manga-offline-cache", isDirectory: true)
    )
    let ordinaryImageCache = RecordingOrdinaryImageCache()
    let appContext = YamiboAppContext(
        sessionStore: SessionStore(defaults: try makeDefaults(suiteName: suiteName), key: "session"),
        checkInStore: YamiboCheckInStore(defaults: try makeDefaults(suiteName: suiteName), keyPrefix: "check-in"),
        settingsStore: settingsStore,
        webDAVSyncSettingsStore: WebDAVSyncSettingsStore(defaults: try makeDefaults(suiteName: suiteName), key: "webdav"),
        readerResumeRouteStore: ReaderResumeRouteStore(defaults: try makeDefaults(suiteName: suiteName), key: "reader-resume-route"),
        novelReaderCacheStore: novelReaderCacheStore,
        favoriteBackgroundImageStore: favoriteBackgroundImageStore,
        mangaDirectoryStore: mangaDirectoryStore,
        mangaReaderProjectionStore: mangaReaderProjectionStore,
        offlineCacheStore: offlineCacheStore,
        forumCacheStore: forumCacheStore,
        ordinaryImageCache: ordinaryImageCache,
        databasePool: database,
        grdbRootDirectory: root
    )

    return SystemSettingsFixture(
        appContext: appContext,
        settingsStore: settingsStore,
        novelReaderCacheStore: novelReaderCacheStore,
        favoriteBackgroundImageStore: favoriteBackgroundImageStore,
        mangaDirectoryStore: mangaDirectoryStore,
        mangaReaderProjectionStore: mangaReaderProjectionStore,
        forumCacheStore: forumCacheStore,
        offlineCacheStore: offlineCacheStore,
        ordinaryImageCache: ordinaryImageCache
    )
}

func mangaOfflineGroupID(_ ownerName: String) -> OfflineCacheGroupID {
    OfflineCacheGroupID(readerKind: .manga, ownerKey: ownerName)
}

func mangaOfflineEntryID(ownerName: String, tid: String) -> OfflineCacheEntryID {
    OfflineCacheEntryID(readerKind: .manga, ownerKey: ownerName, entryKey: tid)
}

func novelOfflineEntryID(
    ownerTitle: String = "小说A",
    tid: String,
    view: Int,
    authorID: String? = nil
) throws -> OfflineCacheEntryID {
    OfflineCacheEntryID(
        readerKind: .novel,
        ownerKey: NovelOfflineCacheEntry.groupKey(
            threadID: tid,
            authorID: authorID
        ),
        entryKey: NovelOfflineCacheEntry.entryKey(
            threadID: tid,
            view: view,
            authorID: authorID
        )
    )
}

final class RecordingOrdinaryImageCache: YamiboOrdinaryImageCacheClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var removeAllCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func removeAllCachedData() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func makeDefaults(suiteName: String) throws -> UserDefaults {
    try XCTUnwrap(UserDefaults(suiteName: suiteName))
}

func makeNovelOfflineCacheEntry(
    ownerTitle: String,
    tid: String,
    view: Int,
    authorID: String? = nil
) throws -> NovelOfflineCacheEntry {
    return NovelOfflineCacheEntry(
        ownerTitle: ownerTitle,
        title: "第\(view)页",
        document: NovelReaderProjection(
            threadID: tid,
            view: view,
            maxView: max(2, view),
            resolvedAuthorID: authorID,
            segments: [.text("小说\(tid)-\(view)", chapterTitle: nil)]
        ),
        updatedAt: Date(timeIntervalSince1970: Double(1_000 + view))
    )
}

func seedNovelCache(_ fixture: SystemSettingsFixture) async throws {
    try await fixture.novelReaderCacheStore.save(
        NovelReaderProjection(
            threadID: "900",
            view: 1,
            maxView: 1,
            segments: [.text("测试小说缓存", chapterTitle: nil)]
        )
    )
}

func seedMangaIndexCache(_ fixture: SystemSettingsFixture) async throws {
    try await fixture.mangaDirectoryStore.saveDirectory(
        MangaDirectory(
            cleanBookName: "测试漫画",
            strategy: .tag,
            sourceKey: "tag:1",
            chapters: [
                MangaChapter(
                    tid: "901",
                    rawTitle: "第1话",
                    chapterNumber: 1
                )
            ],
            lastUpdatedAt: Date(timeIntervalSince1970: 1)
        )
    )
    let sourceIdentity = MangaReaderProjectionSourceIdentity(
        tid: "901",
        authorID: nil,
        view: 1
    )
    try await fixture.mangaReaderProjectionStore.save(MangaReaderProjection(
        tid: "901",
        ownerPostID: "post-901",
        chapterTitle: "第1话",
        imageURLs: [
            try XCTUnwrap(URL(string: "https://img.example.com/901-1.jpg")),
            try XCTUnwrap(URL(string: "https://img.example.com/901-2.jpg"))
        ],
        sourceIdentity: sourceIdentity,
        sourceFingerprint: "settings-fixture"
    ))
}

func seedForumCache(_ fixture: SystemSettingsFixture) async throws {
    try await fixture.forumCacheStore.saveThreadPage(
        makeSystemSettingsOfflineSourcePage(tid: "950"),
        thread: ThreadIdentity(tid: "950")
    )
}

func seedContentCover(_ fixture: SystemSettingsFixture) async throws {
    _ = try await fixture.appContext.contentCoverStore.setAutomaticCover(
        try XCTUnwrap(URL(string: "https://img.example.com/cover.jpg")),
        for: .smartManga(cleanBookName: "测试漫画")
    )
}

func seedMangaDirectory(
    _ fixture: SystemSettingsFixture,
    cleanBookName: String,
    chapterTIDs: [String]
) async throws {
    try await fixture.mangaDirectoryStore.saveDirectory(
        MangaDirectory(
            cleanBookName: cleanBookName,
            strategy: .tag,
            sourceKey: "tag:\(cleanBookName)",
            chapters: chapterTIDs.enumerated().map { index, tid in
                MangaChapter(tid: tid, rawTitle: "第\(index + 1)话", chapterNumber: Double(index + 1))
            }
        )
    )
}

func makeAuthenticatedSession() -> SessionState {
    SessionState(cookie: "\(SessionState.authenticationCookieName)=settings-test-account", isLoggedIn: true)
}

func makeMangaDirectoryTrackedTarget(cleanBookName: String) -> FavoriteUpdateTrackedTarget {
    FavoriteUpdateTrackedTarget(
        target: .mangaDirectory(cleanBookName: cleanBookName),
        title: cleanBookName,
        mode: .mangaDirectory
    )
}

/// Populates all 5 tables `FavoriteUpdateStore.clearAll()` touches (tracked
/// targets, events, runs, fid filters, category filters) so tests can assert
/// every one of them is actually wiped, not just the tracked-targets table.
func seedFavoriteUpdateStoreState(_ fixture: SystemSettingsFixture) async throws {
    let store = fixture.appContext.favoriteUpdateStore
    try await store.upsertTrackedTarget(makeMangaDirectoryTrackedTarget(cleanBookName: "测试漫画"))
    try await store.insertEvent(FavoriteUpdateEvent(
        target: .mangaDirectory(cleanBookName: "测试漫画"),
        title: "测试漫画",
        mode: .mangaDirectory,
        summary: .newChapters(count: 1)
    ))
    try await store.saveRun(FavoriteUpdateRunSnapshot(status: .completed, phase: .completed))
    try await store.replaceFilters(
        fidFilters: [FavoriteUpdateFidFilter(fid: "30", forumName: "测试板块")],
        categoryFilters: [FavoriteUpdateCategoryFilter(categoryID: "cat-1", categoryName: "测试分类")]
    )
}

func seedMangaOfflineCache(_ fixture: SystemSettingsFixture) async throws {
    let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/offline-seed.jpg"))
    try await fixture.offlineCacheStore.saveOfflineImageData(Data(repeating: 9, count: 2048), for: imageURL)
    try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
        try makeMangaOfflineMembership(ownerName: "favorite-seed", tid: "902", imageURLs: [imageURL])
    )
}

func makeMangaOfflineMembership(
    ownerName: String,
    tid: String,
    imageURLs: [URL]
) throws -> MangaOfflineCacheMembership {
    MangaOfflineCacheMembership(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        imageURLs: imageURLs,
        sourcePage: makeSystemSettingsOfflineSourcePage(tid: tid)
    )
}

func makeSystemSettingsOfflineSourcePage(tid: String) -> ForumThreadPage {
    ForumThreadPage(
        thread: ThreadIdentity(tid: tid),
        title: "第\(tid)话",
        posts: [
            ForumThreadPost(
                postID: "p-\(tid)",
                author: BlogReaderUser(uid: "author-\(tid)", name: "作者"),
                contentHTML: "",
                contentText: ""
            )
        ]
    )
}

func makeMangaOfflineWorkRequest(
    ownerName: String,
    tid: String,
    targetImageURLs: [URL]
) throws -> MangaOfflineCacheWorkRequest {
    MangaOfflineCacheWorkRequest(
        ownerName: ownerName,
        tid: tid,
        chapterTitle: "第\(tid)话",
        targetImageURLs: targetImageURLs
    )
}

/// Polls via `YamiboXTestSupport.waitForCondition`, converting a timeout into
/// a test failure instead of a thrown error so assertions after the wait
/// still run and report their own diagnostics.
@MainActor
func waitForSettings(
    timeout: TimeInterval = 2,
    pollInterval: UInt64 = 20_000_000,
    condition: @escaping () async -> Bool
) async throws {
    do {
        try await waitForCondition(
            timeout: .seconds(timeout),
            pollInterval: .nanoseconds(Int64(pollInterval)),
            condition
        )
    } catch is TestWaitTimeoutError {
        XCTFail("Timed out waiting for condition")
    }
}

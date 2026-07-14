import Foundation
import Testing
@testable import YamiboXCore

// MARK: - Test scaffolding

private func makeLibraryStore(function: String = #function) -> FavoriteLibraryStore {
    let suiteName = "favorite-sync-engine-\(function)-\(UUID().uuidString)"
    return FavoriteLibraryStore(
        defaults: UserDefaults(suiteName: suiteName)!,
        key: "favorites"
    )
}

private func makeSnapshot(categoryID: String, categoryName: String = "分类") -> FavoriteRemoteSyncSnapshot {
    FavoriteRemoteSyncSnapshot(
        status: .running,
        targetCategoryID: categoryID,
        targetCategoryName: categoryName,
        phase: .queued,
        logEntries: [.started(categoryName: categoryName)]
    )
}

private actor SyncCallRecorder {
    private(set) var probedThreadIDs: [String] = []
    private(set) var addedThreadIDs: [String] = []
    private(set) var fetchPageCalls = 0

    func recordProbe(_ threadID: String) { probedThreadIDs.append(threadID) }
    func recordAdd(_ threadID: String) { addedThreadIDs.append(threadID) }
    func recordFetch() -> Int {
        fetchPageCalls += 1
        return fetchPageCalls
    }
}

private func threadProbe(_ threadID: String, title: String = "标题") -> FavoriteThreadProbeResult {
    FavoriteThreadProbeResult(
        target: FavoriteItemTarget(kind: .normalThread, threadID: threadID),
        title: title,
        sourceGroup: .forumBoard(id: "fid", label: "版块")
    )
}

private func singlePageClient(
    entries: [YamiboRemoteFavoriteEntry],
    recorder: SyncCallRecorder,
    probe: @escaping @Sendable (YamiboRemoteFavoriteEntry) async throws -> FavoriteThreadProbeResult = { entry in
        threadProbe(entry.threadID, title: entry.title ?? "标题")
    }
) -> FavoriteYamiboSyncClient {
    FavoriteYamiboSyncClient(
        fetchPage: { _ in
            _ = await recorder.recordFetch()
            return FavoriteYamiboRemotePage(entries: entries, currentPage: 1, totalPages: 1)
        },
        probe: { entry in
            await recorder.recordProbe(entry.threadID)
            return try await probe(entry)
        },
        addFavorite: { threadID in
            await recorder.recordAdd(threadID)
        }
    )
}

private func runEngine(
    store: FavoriteLibraryStore,
    client: FavoriteYamiboSyncClient,
    snapshot: FavoriteRemoteSyncSnapshot,
    mangaDirectoryStore: MangaDirectoryStore? = nil,
    settingsStore: SettingsStore? = nil
) async -> FavoriteRemoteSyncSnapshot {
    let engine = FavoriteYamiboSyncEngine(
        libraryStore: store,
        client: client,
        mangaDirectoryStore: mangaDirectoryStore,
        settingsStore: settingsStore
    )
    return await engine.run(snapshot: snapshot, persist: { _ in })
}

private func makeSettingsStore(_ boardReader: BoardReaderSettings) async throws -> SettingsStore {
    let suiteName = "favorite-sync-engine-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let store = SettingsStore(defaults: defaults, key: "settings")
    var settings = AppSettings()
    settings.boardReader = boardReader
    try await store.save(settings)
    return store
}

// MARK: - Importing

@Test func engineImportsRemoteOnlyThreadIntoTargetCategory() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let category = document.createCategory(name: "远端")
    try await store.save(document)

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-901", threadID: "901", title: "远端小说")],
        recorder: recorder
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: category.id))

    #expect(final.status == .completed)
    #expect(final.importedCount == 1)
    #expect(final.uploadTargetCount == 0)
    let saved = try await store.load()
    let item = try #require(saved.items.first)
    #expect(item.locations == [.category(category.id)])
    #expect(item.remoteMapping?.yamiboFavoriteID == "r-901")
    #expect(item.remoteMapping?.yamiboRemoteOrder == 0)
    let probed = await recorder.probedThreadIDs
    #expect(probed == ["901"])
}

@Test func engineImportsMangaChapterViaProbe() async throws {
    // A manga chapter thread now imports as a plain `.mangaThread` favorite
    // of its own thread id through the same generic `importThreadFavorite`
    // path as any other thread — there is no dedicated manga-chapter import
    // mechanism left to test (smart-comic-mode Phase A decision #3/#9).
    let store = makeLibraryStore()
    let document = try await store.load()
    let categoryID = document.defaultCategory.id

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-905", threadID: "905", title: "第5话")],
        recorder: recorder,
        probe: { _ in
            FavoriteThreadProbeResult(
                target: .mangaThread(threadID: "905"),
                title: "漫画书名",
                sourceGroup: .forumBoard(id: "fid-manga", label: "漫画区")
            )
        }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .completed)
    #expect(final.importedCount == 1)
    let saved = try await store.load()
    let item = try #require(saved.items.first)
    #expect(item.target == .mangaThread(threadID: "905"))
    #expect(item.remoteMapping?.yamiboFavoriteID == "r-905")
}

// MARK: - Manga directory attribution warning (smart-comic-mode Phase G)

@Test func engineWarnsWhenImportedMangaChapterSharesDirectoryWithExistingFavorite() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let categoryID = document.defaultCategory.id
    // Pre-existing favorite (from before this sync run) of chapter "910",
    // fid 30 — the default-enabled Smart Comic Mode board.
    let existingSibling = try FavoriteItem(
        target: FavoriteItemTarget(kind: .mangaThread, threadID: "910"),
        title: "第1话",
        sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
        forumID: "30",
        forumName: "中文百合漫画区",
        locations: [.category(categoryID)]
    )
    document.upsertItem(existingSibling)
    try await store.save(document)

    let mangaDirectoryStore = try makeTestMangaDirectoryStore()
    try await mangaDirectoryStore.saveDirectory(MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .tag,
        sourceKey: "测试漫画",
        chapters: [
            MangaChapter(tid: "910", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "911", rawTitle: "第2话", chapterNumber: 2),
        ]
    ))

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-911", threadID: "911", title: "第2话")],
        recorder: recorder,
        probe: { entry in
            FavoriteThreadProbeResult(
                target: .mangaThread(threadID: entry.threadID),
                title: "第2话",
                sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区")
            )
        }
    )
    let final = await runEngine(
        store: store,
        client: client,
        snapshot: makeSnapshot(categoryID: categoryID),
        mangaDirectoryStore: mangaDirectoryStore
    )

    #expect(final.status == .completed)
    #expect(final.warnings.contains { warning in
        if case let .importedIntoExistingMangaDirectory(_, cleanBookName) = warning {
            return cleanBookName == "测试漫画"
        }
        return false
    })
}

@Test func engineSkipsAttributionWarningWhenNewChapterBoardHasSmartComicModeOff() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let categoryID = document.defaultCategory.id
    let existingSibling = try FavoriteItem(
        target: FavoriteItemTarget(kind: .mangaThread, threadID: "910"),
        title: "第1话",
        sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
        forumID: "30",
        forumName: "中文百合漫画区",
        locations: [.category(categoryID)]
    )
    document.upsertItem(existingSibling)
    try await store.save(document)

    let mangaDirectoryStore = try makeTestMangaDirectoryStore()
    try await mangaDirectoryStore.saveDirectory(MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .tag,
        sourceKey: "测试漫画",
        chapters: [
            MangaChapter(tid: "910", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "911", rawTitle: "第2话", chapterNumber: 2),
        ]
    ))
    // The new chapter's own board (46) has Smart Comic Mode off by default —
    // even though the sibling's board (30) has it on, the two-sided check
    // (design decision #8, mirroring Phase F's `autoAttributionDirectoryTitle`
    // fix) must suppress the warning.
    let settingsStore = try await makeSettingsStore(BoardReaderSettings())

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-911", threadID: "911", title: "第2话")],
        recorder: recorder,
        probe: { entry in
            FavoriteThreadProbeResult(
                target: .mangaThread(threadID: entry.threadID),
                title: "第2话",
                sourceGroup: .forumBoard(id: "46", label: "另一个漫画区")
            )
        }
    )
    let final = await runEngine(
        store: store,
        client: client,
        snapshot: makeSnapshot(categoryID: categoryID),
        mangaDirectoryStore: mangaDirectoryStore,
        settingsStore: settingsStore
    )

    #expect(final.status == .completed)
    #expect(!final.warnings.contains { warning in
        if case .importedIntoExistingMangaDirectory = warning { return true }
        return false
    })
}

@Test func engineSkipsAttributionWarningWhenExistingSiblingBoardHasSmartComicModeOff() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let categoryID = document.defaultCategory.id
    // Existing sibling's own board (46) has Smart Comic Mode off, even though
    // the newly-imported chapter's board (30) has it on.
    let existingSibling = try FavoriteItem(
        target: FavoriteItemTarget(kind: .mangaThread, threadID: "910"),
        title: "第1话",
        sourceGroup: .forumBoard(id: "46", label: "另一个漫画区"),
        forumID: "46",
        forumName: "另一个漫画区",
        locations: [.category(categoryID)]
    )
    document.upsertItem(existingSibling)
    try await store.save(document)

    let mangaDirectoryStore = try makeTestMangaDirectoryStore()
    try await mangaDirectoryStore.saveDirectory(MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .tag,
        sourceKey: "测试漫画",
        chapters: [
            MangaChapter(tid: "910", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "911", rawTitle: "第2话", chapterNumber: 2),
        ]
    ))
    let settingsStore = try await makeSettingsStore(BoardReaderSettings())

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-911", threadID: "911", title: "第2话")],
        recorder: recorder,
        probe: { entry in
            FavoriteThreadProbeResult(
                target: .mangaThread(threadID: entry.threadID),
                title: "第2话",
                sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区")
            )
        }
    )
    let final = await runEngine(
        store: store,
        client: client,
        snapshot: makeSnapshot(categoryID: categoryID),
        mangaDirectoryStore: mangaDirectoryStore,
        settingsStore: settingsStore
    )

    #expect(final.status == .completed)
    #expect(!final.warnings.contains { warning in
        if case .importedIntoExistingMangaDirectory = warning { return true }
        return false
    })
}

// Phase G gap (smart-comic-mode design doc, Phase G's "遗留 TODO"/Phase H
// note ②): the adversarial review that shipped alongside Phase G found a bug
// where `directory.chapters.lazy.map(\.tid).first { ... }` picked only the
// chapter-order-first already-favorited sibling to check, so a directory
// with several already-favorited siblings across boards with different mode
// states could miss a later, mode-on sibling because an earlier, mode-off
// one failed the check first and short-circuited the whole lookup. The fix
// (`directory.chapters.contains { ... }`, scanning every candidate) landed
// alongside Phase G, but every existing test here only ever has a single
// pre-existing sibling — none of them can actually distinguish "checks only
// the first candidate" from "checks every candidate". This test uses a
// three-chapter directory with two already-favorited siblings on boards with
// opposite Smart Comic Mode states, the mode-off one sorted first by chapter
// order and the mode-on one sorted later, so a `.first`-based regression
// would silently swallow the warning while `.contains` still fires it.
@Test func engineWarnsWhenALaterSiblingIsModeOnEvenIfAnEarlierSortedSiblingIsModeOff() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let categoryID = document.defaultCategory.id
    // Chapter-order-first sibling (tid "940"): already favorited, but its
    // board (46) has Smart Comic Mode off. A `.first`-based check that stops
    // here would wrongly conclude "no attributed sibling".
    let modeOffSibling = try FavoriteItem(
        target: FavoriteItemTarget(kind: .mangaThread, threadID: "940"),
        title: "第1话",
        sourceGroup: .forumBoard(id: "46", label: "另一个漫画区"),
        forumID: "46",
        forumName: "另一个漫画区",
        locations: [.category(categoryID)]
    )
    // Chapter-order-later sibling (tid "941"): already favorited, board (30)
    // has Smart Comic Mode on — this is the one that must actually get
    // checked for the warning to fire.
    let modeOnSibling = try FavoriteItem(
        target: FavoriteItemTarget(kind: .mangaThread, threadID: "941"),
        title: "第2话",
        sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区"),
        forumID: "30",
        forumName: "中文百合漫画区",
        locations: [.category(categoryID)]
    )
    document.upsertItem(modeOffSibling)
    document.upsertItem(modeOnSibling)
    try await store.save(document)

    let mangaDirectoryStore = try makeTestMangaDirectoryStore()
    try await mangaDirectoryStore.saveDirectory(MangaDirectory(
        cleanBookName: "多兄弟测试漫画",
        strategy: .tag,
        sourceKey: "多兄弟测试漫画",
        chapters: [
            MangaChapter(tid: "940", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "941", rawTitle: "第2话", chapterNumber: 2),
            MangaChapter(tid: "942", rawTitle: "第3话", chapterNumber: 3),
        ]
    ))
    let settingsStore = try await makeSettingsStore(BoardReaderSettings())

    // New import (tid "942", chapter 3) also lands on a Smart-Comic-Mode-on
    // board (30).
    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-942", threadID: "942", title: "第3话")],
        recorder: recorder,
        probe: { entry in
            FavoriteThreadProbeResult(
                target: .mangaThread(threadID: entry.threadID),
                title: "第3话",
                sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区")
            )
        }
    )
    let final = await runEngine(
        store: store,
        client: client,
        snapshot: makeSnapshot(categoryID: categoryID),
        mangaDirectoryStore: mangaDirectoryStore,
        settingsStore: settingsStore
    )

    #expect(final.status == .completed)
    #expect(final.warnings.contains { warning in
        if case let .importedIntoExistingMangaDirectory(_, cleanBookName) = warning {
            return cleanBookName == "多兄弟测试漫画"
        }
        return false
    })
}

@Test func engineSkipsAttributionWarningBetweenTwoSiblingsNewlyImportedInSameRun() async throws {
    // Two chapters of the same directory, neither favorited before this run
    // started — importing one must not warn about the other, since "already
    // favorited" means favorited *before* this sync run began.
    let store = makeLibraryStore()
    let document = try await store.load()
    let categoryID = document.defaultCategory.id

    let mangaDirectoryStore = try makeTestMangaDirectoryStore()
    try await mangaDirectoryStore.saveDirectory(MangaDirectory(
        cleanBookName: "测试漫画",
        strategy: .tag,
        sourceKey: "测试漫画",
        chapters: [
            MangaChapter(tid: "920", rawTitle: "第1话", chapterNumber: 1),
            MangaChapter(tid: "921", rawTitle: "第2话", chapterNumber: 2),
        ]
    ))

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [
            YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-920", threadID: "920", title: "第1话"),
            YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-921", threadID: "921", title: "第2话"),
        ],
        recorder: recorder,
        probe: { entry in
            FavoriteThreadProbeResult(
                target: .mangaThread(threadID: entry.threadID),
                title: entry.title ?? "",
                sourceGroup: .forumBoard(id: "30", label: "中文百合漫画区")
            )
        }
    )
    let final = await runEngine(
        store: store,
        client: client,
        snapshot: makeSnapshot(categoryID: categoryID),
        mangaDirectoryStore: mangaDirectoryStore
    )

    #expect(final.status == .completed)
    #expect(final.importedCount == 2)
    #expect(!final.warnings.contains { warning in
        if case .importedIntoExistingMangaDirectory = warning { return true }
        return false
    })
}

@Test func engineAddsCategoryLocationToExistingUnmappedItemWithoutProbe() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let category = document.createCategory(name: "远端")
    let existing = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "902"),
        title: "本地已有",
        locations: [.category(document.defaultCategory.id)]
    )
    document.upsertItem(existing)
    try await store.save(document)

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-902", threadID: "902")],
        recorder: recorder
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: category.id))

    #expect(final.status == .completed)
    #expect(final.importedCount == 1)
    #expect(final.skippedCount == 0)
    let saved = try await store.load()
    let item = try #require(saved.items.first)
    #expect(Set(item.locations) == [.category(document.defaultCategory.id), .category(category.id)])
    #expect(item.remoteMapping?.yamiboFavoriteID == "r-902")
    let probed = await recorder.probedThreadIDs
    #expect(probed.isEmpty)
}

@Test func engineSkipsAlreadyMappedItemAndRefreshesMapping() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let existing = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "903"),
        title: "已映射",
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "r-old", yamiboRemoteOrder: 9),
        locations: [.category(document.defaultCategory.id)]
    )
    document.upsertItem(existing)
    let categoryID = document.defaultCategory.id
    try await store.save(document)

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-new", threadID: "903")],
        recorder: recorder
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .completed)
    #expect(final.skippedCount == 1)
    #expect(final.importedCount == 0)
    #expect(final.logEntries.contains { entry in
        if case .skippedSyncedItems = entry { return true }
        return false
    })
    let saved = try await store.load()
    let item = try #require(saved.items.first)
    #expect(item.remoteMapping?.yamiboFavoriteID == "r-new")
    #expect(item.remoteMapping?.yamiboRemoteOrder == 0)
}

@Test func engineRecordsItemFailureAndContinues() async throws {
    let store = makeLibraryStore()
    let document = try await store.load()
    let categoryID = document.defaultCategory.id

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [
            YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-bad", threadID: "111", title: "坏帖"),
            YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-good", threadID: "222", title: "好帖"),
        ],
        recorder: recorder,
        probe: { entry in
            if entry.threadID == "111" {
                throw YamiboError.parsingFailed(context: "boom")
            }
            return threadProbe(entry.threadID)
        }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .completed)
    #expect(final.failedCount == 1)
    #expect(final.importedCount == 1)
    #expect(final.warnings.contains { warning in
        if case .importFailedItem = warning { return true }
        return false
    })
    let saved = try await store.load()
    #expect(saved.items.count == 1)
    // Failed probes retry before giving up: 3 attempts for the bad entry.
    let probed = await recorder.probedThreadIDs
    #expect(probed.filter { $0 == "111" }.count == 3)
}

@Test func engineFailsItemWithUnresolvedSourceMetadataInsteadOfImporting() async throws {
    let store = makeLibraryStore()
    let document = try await store.load()
    let categoryID = document.defaultCategory.id

    let recorder = SyncCallRecorder()
    let client = singlePageClient(
        entries: [YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-906", threadID: "906", title: "来源未知")],
        recorder: recorder,
        probe: { entry in
            FavoriteThreadProbeResult(
                target: FavoriteItemTarget(kind: .normalThread, threadID: entry.threadID),
                title: "来源未知",
                sourceGroup: .unknown,
                sourceMetadataFetchFailed: true
            )
        }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .completed)
    #expect(final.importedCount == 0)
    #expect(final.failedCount == 1)
    #expect(final.warnings.contains { warning in
        if case .importFailedItem = warning { return true }
        return false
    })
    let saved = try await store.load()
    #expect(saved.items.isEmpty)
}

// MARK: - Uploading & reconciling

@Test func engineUploadsLocalOnlyThreadsIncludingRemoteDeletedAndReconciles() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let categoryID = document.defaultCategory.id
    let unmapped = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "301"),
        title: "从未同步",
        locations: [.category(categoryID)]
    )
    // Mapped but no longer on the website: local is truth, so sync re-uploads it.
    let remoteDeleted = try FavoriteItem(
        target: FavoriteItemTarget(kind: .novelThread, threadID: "302"),
        title: "网站已删",
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "r-302-old"),
        locations: [.category(categoryID)]
    )
    // (No threadID-less "manga" distractor item anymore: every
    // `FavoriteItemTarget` case now carries a real thread id — including
    // `.mangaThread` — so there is no favorite kind left that the upload
    // filter's `item.target.threadID.map { ... }` would ever skip for
    // lacking one. See smart-comic-mode Phase A decision #3/#9.)
    document.upsertItem(unmapped)
    document.upsertItem(remoteDeleted)
    try await store.save(document)

    let recorder = SyncCallRecorder()
    let client = FavoriteYamiboSyncClient(
        fetchPage: { _ in
            // First fetch (phase 2) sees an empty remote list; the reconcile
            // fetch after uploading sees both uploaded threads.
            let call = await recorder.recordFetch()
            if call == 1 {
                return FavoriteYamiboRemotePage(entries: [], currentPage: 1, totalPages: 1)
            }
            return FavoriteYamiboRemotePage(
                entries: [
                    YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-301", threadID: "301"),
                    YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-302", threadID: "302"),
                ],
                currentPage: 1,
                totalPages: 1
            )
        },
        probe: { entry in
            await recorder.recordProbe(entry.threadID)
            return threadProbe(entry.threadID)
        },
        addFavorite: { threadID in
            await recorder.recordAdd(threadID)
        }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .completed)
    #expect(final.uploadTargetCount == 2)
    #expect(final.uploadedCount == 2)
    let added = await recorder.addedThreadIDs
    #expect(Set(added) == ["301", "302"])
    let saved = try await store.load()
    let savedUnmapped = try #require(saved.items.first { $0.target.threadID == "301" })
    let savedRemoteDeleted = try #require(saved.items.first { $0.target.threadID == "302" })
    #expect(savedUnmapped.remoteMapping?.yamiboFavoriteID == "r-301")
    #expect(savedRemoteDeleted.remoteMapping?.yamiboFavoriteID == "r-302")
}

@Test func engineWarnsWhenRemoteFavoritesEmptyBeforeBulkUpload() async throws {
    let store = makeLibraryStore()
    var document = try await store.load()
    let categoryID = document.defaultCategory.id
    let localOnly = try FavoriteItem(
        target: FavoriteItemTarget(kind: .normalThread, threadID: "401"),
        title: "本地专属",
        locations: [.category(categoryID)]
    )
    document.upsertItem(localOnly)
    try await store.save(document)

    let recorder = SyncCallRecorder()
    let client = FavoriteYamiboSyncClient(
        fetchPage: { _ in
            _ = await recorder.recordFetch()
            return FavoriteYamiboRemotePage(entries: [], currentPage: 1, totalPages: 1)
        },
        probe: { entry in threadProbe(entry.threadID) },
        addFavorite: { threadID in await recorder.recordAdd(threadID) }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .completed)
    #expect(final.uploadedCount == 1)
    let hasWarning = final.warnings.contains { warning in
        if case let .remoteFavoritesEmptyBeforeBulkUpload(count) = warning {
            return count == 1
        }
        return false
    }
    #expect(hasWarning)
    let added = await recorder.addedThreadIDs
    #expect(added == ["401"])
}

// MARK: - Fetching

@Test func enginePaginatesAndRecordsProgress() async throws {
    let store = makeLibraryStore()
    let document = try await store.load()
    let categoryID = document.defaultCategory.id

    let recorder = SyncCallRecorder()
    let client = FavoriteYamiboSyncClient(
        fetchPage: { page in
            _ = await recorder.recordFetch()
            let entry = YamiboRemoteFavoriteEntry(remoteFavoriteID: "r-\(page)", threadID: "\(1000 + page)")
            return FavoriteYamiboRemotePage(entries: [entry], currentPage: page, totalPages: 2)
        },
        probe: { entry in
            await recorder.recordProbe(entry.threadID)
            return threadProbe(entry.threadID)
        },
        addFavorite: { _ in }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .completed)
    #expect(final.scannedCount == 2)
    #expect(final.currentPage == 2)
    #expect(final.totalPages == 2)
    #expect(final.importedCount == 2)
    let fetchedPageLogs = final.logEntries.filter { entry in
        if case .fetchedPage = entry { return true }
        return false
    }
    #expect(fetchedPageLogs.count == 2)
}

// MARK: - Failure modes

@Test func engineFailsRunOnNotAuthenticated() async throws {
    let store = makeLibraryStore()
    let document = try await store.load()
    let categoryID = document.defaultCategory.id

    let client = FavoriteYamiboSyncClient(
        fetchPage: { _ in throw YamiboError.notAuthenticated },
        probe: { _ in throw YamiboError.notAuthenticated },
        addFavorite: { _ in }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .failed)
    #expect(final.phase == .failed)
    #expect(!final.errorMessages.isEmpty)
}

@Test func engineFailsRunWhenPageOneFetchNeverParses() async throws {
    let store = makeLibraryStore()
    let document = try await store.load()
    let categoryID = document.defaultCategory.id

    let client = FavoriteYamiboSyncClient(
        fetchPage: { _ in throw YamiboError.parsingFailed(context: "boom") },
        probe: { entry in threadProbe(entry.threadID) },
        addFavorite: { _ in }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    // Previously a parsingFailed error on page 1 was silently reinterpreted
    // as "confirmed empty account"; it must now fail the whole run like any
    // other page.
    #expect(final.status == .failed)
    #expect(final.phase == .failed)
}

@Test func engineRetriesTransientFetchPageFailureThenSucceeds() async throws {
    let store = makeLibraryStore()
    let document = try await store.load()
    let categoryID = document.defaultCategory.id

    let recorder = SyncCallRecorder()
    let client = FavoriteYamiboSyncClient(
        fetchPage: { _ in
            let call = await recorder.recordFetch()
            if call < 3 {
                throw YamiboError.parsingFailed(context: "boom")
            }
            return FavoriteYamiboRemotePage(entries: [], currentPage: 1, totalPages: 1)
        },
        probe: { entry in threadProbe(entry.threadID) },
        addFavorite: { _ in }
    )
    let final = await runEngine(store: store, client: client, snapshot: makeSnapshot(categoryID: categoryID))

    #expect(final.status == .completed)
    let fetches = await recorder.fetchPageCalls
    #expect(fetches == 3)
}

@Test func engineFailsWhenTargetCategoryMissing() async throws {
    let store = makeLibraryStore()
    let recorder = SyncCallRecorder()
    let client = singlePageClient(entries: [], recorder: recorder)

    let final = await runEngine(
        store: store,
        client: client,
        snapshot: makeSnapshot(categoryID: "no-such-category")
    )

    #expect(final.status == .failed)
    let fetches = await recorder.fetchPageCalls
    #expect(fetches == 0)
}

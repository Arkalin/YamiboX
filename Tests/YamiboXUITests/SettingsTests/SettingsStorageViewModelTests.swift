import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

// The storage page's slice (usage counters, cache clearing, application
// reset) of the former SystemSettingsViewModelTests. Application reset fans
// out to the sibling page models, so those assertions go through the
// composition root's other pages.
@MainActor
final class SettingsStorageViewModelTests: XCTestCase {
    func testClearReadingProgressPreservesHistoryAndCaches() async throws {
        let fixture = try makeSystemSettingsFixture()
        let progress = fixture.appContext.readingProgressStore
        let history = fixture.appContext.browsingHistoryStore
        try await progress.saveNormalThread(threadID: "100", page: 3)
        try await history.record(BrowsingHistoryEntry(target: .normalThread(threadID: "100"), title: "Thread"))
        try await seedNovelCache(fixture)
        let cacheBytes = await fixture.novelReaderCacheStore.totalDiskUsageBytes()
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)

        let didClear = await settings.storage.clearReadingProgress()

        let records = await progress.loadAll()
        let entries = await history.entries()
        let remainingBytes = await fixture.novelReaderCacheStore.totalDiskUsageBytes()
        XCTAssertTrue(didClear)
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(remainingBytes, cacheBytes)
        XCTAssertFalse(settings.storage.isBusy)
        XCTAssertNil(settings.storage.errorMessage)
        XCTAssertEqual(settings.storage.readingProgressBytes, 0)
        XCTAssertGreaterThan(try XCTUnwrap(settings.storage.browsingHistoryBytes), 0)
    }

    func testClearBrowsingHistoryPreservesReadingProgress() async throws {
        let fixture = try makeSystemSettingsFixture()
        let progress = fixture.appContext.readingProgressStore
        let history = fixture.appContext.browsingHistoryStore
        try await progress.saveNormalThread(threadID: "100", page: 3)
        let savedProgress = await progress.loadAll()
        XCTAssertEqual(savedProgress.count, 1)
        try await history.record(BrowsingHistoryEntry(target: .normalThread(threadID: "100"), title: "Thread"))
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)

        let didClear = await settings.storage.clearBrowsingHistory()

        let records = await progress.loadAll()
        let entries = await history.entries()
        XCTAssertTrue(didClear)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(records, savedProgress)
        XCTAssertEqual(settings.storage.browsingHistoryBytes, 0)
        XCTAssertGreaterThan(try XCTUnwrap(settings.storage.readingProgressBytes), 0)
        XCTAssertFalse(settings.storage.isBusy)
        XCTAssertNil(settings.storage.errorMessage)
    }

    func testLoadReadsStorageUsageAcrossAllCacheCategories() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedNovelCache(fixture)
        try await seedMangaIndexCache(fixture)
        try await seedForumCache(fixture)
        try await seedContentCover(fixture)
        try await seedMangaOfflineCache(fixture)
        fixture.ordinaryImageCache.diskUsageBytes = 2048
        await fixture.appContext.checkInStore.markCheckedIn(session: makeAuthenticatedSession())
        try await seedFavoriteUpdateStoreState(fixture)
        try await fixture.appContext.readingProgressStore.saveNormalThread(threadID: "100", page: 3)
        try await fixture.appContext.browsingHistoryStore.record(
            BrowsingHistoryEntry(target: .normalThread(threadID: "100"), title: "Thread")
        )

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.storage
        await settings.load()

        XCTAssertNil(viewModel.imageCacheBytes, "The root must defer the image scan until the storage page opens")
        XCTAssertEqual(viewModel.imageCacheLabel, L10n.string("settings.storage_usage_calculating"))
        await viewModel.refreshStorageUsage()
        let checkInBytes = await fixture.appContext.checkInStore.estimatedDataUsageBytes()
        let updateBytes = try await fixture.appContext.favoriteUpdateStore.estimatedDataUsageBytes()
        XCTAssertEqual(viewModel.imageCacheBytes, 2048)
        XCTAssertEqual(viewModel.otherCacheBytes, checkInBytes + updateBytes + URLCache.shared.currentDiskUsage)
        XCTAssertGreaterThan(try XCTUnwrap(viewModel.readingProgressBytes), 0)
        XCTAssertGreaterThan(try XCTUnwrap(viewModel.browsingHistoryBytes), 0)

        XCTAssertGreaterThan(viewModel.webReaderCacheBytes, 0)
        XCTAssertGreaterThan(viewModel.contentCoverCacheBytes, 0)
        XCTAssertGreaterThan(viewModel.mangaDirectoryCacheBytes, 0)
        XCTAssertGreaterThan(viewModel.offlineCacheBytes, 0)
        XCTAssertEqual(viewModel.webReaderCacheLabel, cacheLabel(for: viewModel.webReaderCacheBytes))
        XCTAssertEqual(viewModel.contentCoverCacheLabel, cacheLabel(for: viewModel.contentCoverCacheBytes))
        XCTAssertEqual(viewModel.mangaDirectoryCacheLabel, cacheLabel(for: viewModel.mangaDirectoryCacheBytes))
        XCTAssertEqual(viewModel.offlineCacheLabel, cacheLabel(for: viewModel.offlineCacheBytes))
        XCTAssertEqual(viewModel.imageCacheLabel, cacheLabel(for: 2048))
        XCTAssertEqual(viewModel.otherCacheLabel, cacheLabel(for: try XCTUnwrap(viewModel.otherCacheBytes)))
        XCTAssertEqual(viewModel.readingProgressLabel, cacheLabel(for: try XCTUnwrap(viewModel.readingProgressBytes)))
        XCTAssertEqual(viewModel.browsingHistoryLabel, cacheLabel(for: try XCTUnwrap(viewModel.browsingHistoryBytes)))
    }

    func testClearWebReaderCacheClearsNovelMangaProjectionAndForumCacheOnly() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedNovelCache(fixture)
        try await seedMangaIndexCache(fixture)
        try await seedForumCache(fixture)
        try await seedMangaOfflineCache(fixture)

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.storage
        await settings.load()
        let novelBytesBeforeClear = await fixture.novelReaderCacheStore.totalDiskUsageBytes()
        let projectionBytesBeforeClear = await fixture.mangaReaderProjectionStore.totalDiskUsageBytes()
        let forumBytesBeforeClear = await fixture.forumCacheStore.totalDiskUsageBytes()
        let directoryBytesBeforeClear = await fixture.mangaDirectoryStore.totalDiskUsageBytes()
        let offlineBytesBeforeClear = await fixture.offlineCacheStore.totalDiskUsageBytes()

        let didClear = await viewModel.clearWebReaderCache()
        let novelBytesAfterClear = await fixture.novelReaderCacheStore.totalDiskUsageBytes()
        let projectionBytesAfterClear = await fixture.mangaReaderProjectionStore.totalDiskUsageBytes()
        let forumBytesAfterClear = await fixture.forumCacheStore.totalDiskUsageBytes()
        let directoryBytesAfterClear = await fixture.mangaDirectoryStore.totalDiskUsageBytes()
        let offlineBytesAfterClear = await fixture.offlineCacheStore.totalDiskUsageBytes()
        let offlineMembershipAfterClear = await fixture.offlineCacheStore.mangaOfflineCacheMembership(
            ownerName: "favorite-seed",
            tid: "902"
        )

        XCTAssertTrue(didClear)
        XCTAssertGreaterThan(novelBytesBeforeClear, 0)
        XCTAssertGreaterThan(projectionBytesBeforeClear, 0)
        XCTAssertGreaterThan(forumBytesBeforeClear, 0)
        XCTAssertGreaterThan(directoryBytesBeforeClear, 0)
        XCTAssertGreaterThan(offlineBytesBeforeClear, 0)
        XCTAssertEqual(novelBytesAfterClear, 0)
        XCTAssertEqual(projectionBytesAfterClear, 0)
        XCTAssertEqual(forumBytesAfterClear, 0)
        XCTAssertEqual(directoryBytesAfterClear, directoryBytesBeforeClear)
        XCTAssertEqual(offlineBytesAfterClear, offlineBytesBeforeClear)
        XCTAssertNotNil(offlineMembershipAfterClear)
        XCTAssertEqual(viewModel.webReaderCacheBytes, 0)
        XCTAssertEqual(viewModel.mangaDirectoryCacheBytes, directoryBytesBeforeClear)
        XCTAssertEqual(viewModel.offlineCacheBytes, offlineBytesBeforeClear)
    }

    func testClearContentCoverCacheClearsOnlyContentCovers() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedContentCover(fixture)
        try await seedNovelCache(fixture)

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.storage
        await settings.load()
        let novelBytesBeforeClear = await fixture.novelReaderCacheStore.totalDiskUsageBytes()

        let didClear = await viewModel.clearContentCoverCache()
        let coverAfterClear = await fixture.appContext.contentCoverStore.cover(for: .smartManga(cleanBookName: "测试漫画"))
        let novelBytesAfterClear = await fixture.novelReaderCacheStore.totalDiskUsageBytes()

        XCTAssertTrue(didClear)
        XCTAssertNil(coverAfterClear)
        XCTAssertEqual(novelBytesAfterClear, novelBytesBeforeClear)
        XCTAssertEqual(viewModel.contentCoverCacheBytes, 0)
    }

    func testClearOtherCachesClearsCheckInAndFavoriteUpdateStoreOnly() async throws {
        let fixture = try makeSystemSettingsFixture()
        let session = makeAuthenticatedSession()
        await fixture.appContext.checkInStore.markCheckedIn(session: session)
        try await seedFavoriteUpdateStoreState(fixture)
        try await seedNovelCache(fixture)

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.storage
        await settings.load()
        let novelBytesBeforeClear = await fixture.novelReaderCacheStore.totalDiskUsageBytes()

        let didClear = await viewModel.clearOtherCaches()
        let needsCheckInAfterClear = await fixture.appContext.checkInStore.needsCheckIn(session: session)
        let stateAfterClear = await fixture.appContext.favoriteUpdateStore.loadState()
        let novelBytesAfterClear = await fixture.novelReaderCacheStore.totalDiskUsageBytes()

        XCTAssertTrue(didClear)
        XCTAssertTrue(needsCheckInAfterClear)
        XCTAssertTrue(stateAfterClear.trackedTargets.isEmpty)
        XCTAssertTrue(stateAfterClear.events.isEmpty)
        XCTAssertTrue(stateAfterClear.runs.isEmpty)
        XCTAssertTrue(stateAfterClear.fidFilters.isEmpty)
        XCTAssertTrue(stateAfterClear.categoryFilters.isEmpty)
        XCTAssertEqual(novelBytesAfterClear, novelBytesBeforeClear)
        XCTAssertEqual(viewModel.otherCacheBytes, URLCache.shared.currentDiskUsage)
    }

    func testClearImageCachePreservesReaderAndUserOwnedCaches() async throws {
        let fixture = try makeSystemSettingsFixture()
        fixture.ordinaryImageCache.diskUsageBytes = 4096
        try await seedNovelCache(fixture)
        try await seedMangaIndexCache(fixture)
        let offlineImageURL = try XCTUnwrap(URL(string: "https://img.example.com/offline-settings.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data(repeating: 4, count: 1024), for: offlineImageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "903", imageURLs: [offlineImageURL])
        )
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeMangaOfflineWorkRequest(
                ownerName: "作品B",
                tid: "904",
                targetImageURLs: [try XCTUnwrap(URL(string: "https://img.example.com/offline-work.jpg"))]
            )
        )
        let favoriteBackgroundID = "settings-background"
        try await fixture.favoriteBackgroundImageStore.save(
            Data(repeating: 5, count: 128),
            imageID: favoriteBackgroundID
        )
        try await fixture.settingsStore.save(AppSettings(
            favorites: FavoriteLibrarySettings(background: FavoriteBackgroundSettings(isEnabled: true, imageID: favoriteBackgroundID)),
            system: SystemSettings(homePage: .favorites)
        ))
        var favoriteLibrary = FavoriteLibraryDocument()
        favoriteLibrary.upsertItem(try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "905"),
            title: "收藏条目",
            locations: [.category(favoriteLibrary.defaultCategory.id)]
        ))
        try await fixture.appContext.localFavoriteLibraryStore.save(favoriteLibrary)

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.storage
        await settings.load()
        let webReaderBytesBeforeClear = viewModel.webReaderCacheBytes
        let mangaDirectoryBytesBeforeClear = viewModel.mangaDirectoryCacheBytes
        let offlineBytesBeforeClear = await fixture.offlineCacheStore.totalDiskUsageBytes()

        let didClear = await viewModel.clearImageCache()
        let novelBytesAfterClear = await fixture.novelReaderCacheStore.totalDiskUsageBytes()
        let projectionBytesAfterClear = await fixture.mangaReaderProjectionStore.totalDiskUsageBytes()
        let forumBytesAfterClear = await fixture.forumCacheStore.totalDiskUsageBytes()
        let webReaderBytesAfterClear = novelBytesAfterClear + projectionBytesAfterClear + forumBytesAfterClear
        let mangaDirectoryBytesAfterClear = await fixture.mangaDirectoryStore.totalDiskUsageBytes()
        let offlineBytesAfterClear = await fixture.offlineCacheStore.totalDiskUsageBytes()
        let offlineMembershipAfterClear = await fixture.offlineCacheStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "903")
        let offlineWorkAfterClear = await fixture.offlineCacheStore.mangaQueueWork(ownerName: "作品B", tid: "904")
        let favoriteBackgroundDataAfterClear = await fixture.favoriteBackgroundImageStore.loadData(imageID: favoriteBackgroundID)
        let settingsAfterClear = await fixture.settingsStore.load()
        let favoriteLibraryAfterClear = try await fixture.appContext.localFavoriteLibraryStore.load()

        XCTAssertTrue(didClear)
        XCTAssertEqual(fixture.ordinaryImageCache.removeAllCallCount, 1)
        XCTAssertEqual(viewModel.imageCacheBytes, 0)
        XCTAssertEqual(webReaderBytesAfterClear, webReaderBytesBeforeClear)
        XCTAssertEqual(mangaDirectoryBytesAfterClear, mangaDirectoryBytesBeforeClear)
        XCTAssertEqual(offlineBytesAfterClear, offlineBytesBeforeClear)
        XCTAssertNotNil(offlineMembershipAfterClear)
        XCTAssertNotNil(offlineWorkAfterClear)
        XCTAssertEqual(favoriteBackgroundDataAfterClear, Data(repeating: 5, count: 128))
        XCTAssertEqual(settingsAfterClear.system.homePage, .favorites)
        XCTAssertEqual(settingsAfterClear.favorites.background.imageID, favoriteBackgroundID)
        XCTAssertEqual(favoriteLibraryAfterClear, favoriteLibrary)
        XCTAssertEqual(viewModel.webReaderCacheBytes, webReaderBytesBeforeClear)
        XCTAssertEqual(viewModel.mangaDirectoryCacheBytes, mangaDirectoryBytesBeforeClear)
        XCTAssertEqual(viewModel.offlineCacheBytes, offlineBytesBeforeClear)
    }

    func testResetApplicationRestoresDefaultApplePencilSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings(
            novelOfflineCache: NovelOfflineCacheSettings(
                retainsInlineImages: true,
                isAutoRefreshEnabled: false
            ),
            system: SystemSettings(
                enhancedCheckInEnabled: true,
                applePencilPageTurn: ApplePencilPageTurnSettings(
                    isEnabled: true,
                    behavior: .doubleTapNextSqueezePrevious
                )
            ),
            boardReader: {
                var custom = BoardReaderSettings()
                custom.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
                custom.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "37")
                custom.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "30")
                return custom
            }(),
            appearance: AppAppearanceSettings(themePreset: .rose)
        ))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.load()
        let didReset = await settings.storage.resetApplication()

        XCTAssertTrue(didReset)
        XCTAssertEqual(settings.reading.novelOfflineCache, NovelOfflineCacheSettings())
        XCTAssertEqual(settings.peripherals.applePencilPageTurn, ApplePencilPageTurnSettings())
        XCTAssertEqual(settings.forum.boardReader, BoardReaderSettings())
        XCTAssertFalse(settings.forum.enhancedCheckInEnabled)
        XCTAssertEqual(settings.general.themePreset, .classic)
        let loaded = await fixture.settingsStore.load()
        XCTAssertEqual(loaded.novelOfflineCache, NovelOfflineCacheSettings())
        XCTAssertEqual(loaded.system.applePencilPageTurn, ApplePencilPageTurnSettings())
        XCTAssertFalse(loaded.system.enhancedCheckInEnabled)
        XCTAssertEqual(loaded.appearance.themePreset, .classic)
        XCTAssertEqual(settings.favorites.favoriteBackground, FavoriteBackgroundSettings())
    }

    func testResetApplicationClearsStorageUsageCounters() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedNovelCache(fixture)
        try await seedMangaIndexCache(fixture)
        try await seedMangaOfflineCache(fixture)

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.storage
        await settings.load()
        XCTAssertGreaterThan(viewModel.webReaderCacheBytes, 0)
        XCTAssertGreaterThan(viewModel.mangaDirectoryCacheBytes, 0)
        XCTAssertGreaterThan(viewModel.offlineCacheBytes, 0)

        let didReset = await viewModel.resetApplication()
        let offlineBytesAfterReset = await fixture.offlineCacheStore.totalDiskUsageBytes()
        let offlineMembershipAfterReset = await fixture.offlineCacheStore.mangaOfflineCacheMembership(
            ownerName: "favorite-seed",
            tid: "902"
        )

        XCTAssertTrue(didReset)
        XCTAssertEqual(fixture.ordinaryImageCache.removeAllCallCount, 1)
        XCTAssertEqual(viewModel.webReaderCacheBytes, 0)
        XCTAssertEqual(viewModel.mangaDirectoryCacheBytes, 0)
        XCTAssertEqual(viewModel.offlineCacheBytes, 0)
        XCTAssertEqual(viewModel.imageCacheBytes, 0)
        XCTAssertEqual(viewModel.otherCacheBytes, 0)
        XCTAssertEqual(viewModel.readingProgressBytes, 0)
        XCTAssertEqual(viewModel.browsingHistoryBytes, 0)
        XCTAssertEqual(offlineBytesAfterReset, 0)
        XCTAssertNil(offlineMembershipAfterReset)
    }

    /// Regression test for the bug where `resetApplicationData()` claimed to
    /// wipe "全部缓存" but never actually cleared the per-account check-in
    /// date cache or the favorites-update tracking state (tracked targets,
    /// detected events, run history, fid/category filters).
    func testResetApplicationClearsCheckInAndFavoriteUpdateStores() async throws {
        let fixture = try makeSystemSettingsFixture()
        let session = makeAuthenticatedSession()
        await fixture.appContext.checkInStore.markCheckedIn(session: session)
        try await seedFavoriteUpdateStoreState(fixture)
        let needsCheckInBeforeReset = await fixture.appContext.checkInStore.needsCheckIn(session: session)
        let stateBeforeReset = await fixture.appContext.favoriteUpdateStore.loadState()
        XCTAssertFalse(needsCheckInBeforeReset)
        XCTAssertFalse(stateBeforeReset.trackedTargets.isEmpty)
        XCTAssertFalse(stateBeforeReset.events.isEmpty)
        XCTAssertFalse(stateBeforeReset.runs.isEmpty)
        XCTAssertFalse(stateBeforeReset.fidFilters.isEmpty)
        XCTAssertFalse(stateBeforeReset.categoryFilters.isEmpty)

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let didReset = await settings.storage.resetApplication()

        let needsCheckInAfterReset = await fixture.appContext.checkInStore.needsCheckIn(session: session)
        let stateAfterReset = await fixture.appContext.favoriteUpdateStore.loadState()

        XCTAssertTrue(didReset)
        XCTAssertTrue(needsCheckInAfterReset)
        XCTAssertTrue(stateAfterReset.trackedTargets.isEmpty)
        XCTAssertTrue(stateAfterReset.events.isEmpty)
        XCTAssertTrue(stateAfterReset.runs.isEmpty)
        XCTAssertTrue(stateAfterReset.fidFilters.isEmpty)
        XCTAssertTrue(stateAfterReset.categoryFilters.isEmpty)
    }

    func testStorageRefreshDoesNotBlockActionsAndPicksUpNewData() async throws {
        let fixture = try makeSystemSettingsFixture()
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.storage.refreshStorageUsage()
        XCTAssertFalse(settings.isBusy)
        XCTAssertEqual(settings.storage.imageCacheBytes, 0)
        XCTAssertEqual(settings.storage.readingProgressBytes, 0)
        XCTAssertEqual(settings.storage.browsingHistoryBytes, 0)

        fixture.ordinaryImageCache.diskUsageBytes = 512
        try await fixture.appContext.readingProgressStore.saveNormalThread(threadID: "200", page: 1)
        await settings.storage.refreshStorageUsage()
        XCTAssertEqual(settings.storage.imageCacheBytes, 512)
        XCTAssertGreaterThan(try XCTUnwrap(settings.storage.readingProgressBytes), 0)
    }

    func testFailedStatisticsAreUnavailableRatherThanZero() async throws {
        let fixture = try makeSystemSettingsFixture()
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        try await fixture.appContext.databasePool.write { db in
            try db.execute(sql: "DROP TABLE browsing_history")
            try db.execute(sql: "DROP TABLE favorite_update_runs")
        }
        await settings.storage.refreshStorageUsage()
        XCTAssertNil(settings.storage.browsingHistoryBytes)
        XCTAssertNil(settings.storage.otherCacheBytes)
        XCTAssertEqual(settings.storage.browsingHistoryLabel, L10n.string("settings.storage_usage_unavailable"))
        XCTAssertEqual(settings.storage.otherCacheLabel, L10n.string("settings.storage_usage_unavailable"))
        XCTAssertEqual(settings.storage.readingProgressBytes, 0)
    }

    func testPartialClearRefreshesStatisticsEvenWhenLaterStoreFails() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedNovelCache(fixture)
        try await seedForumCache(fixture)
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.storage.refreshStorageUsage()
        XCTAssertGreaterThan(settings.storage.webReaderCacheBytes, 0)
        try await fixture.appContext.databasePool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_cache_delete BEFORE DELETE ON cache_entries
                WHEN OLD.namespace = 'forum-thread-pages'
                BEGIN SELECT RAISE(ABORT, 'test failure'); END
                """)
        }
        // A failed clear keeps the displayed count consistent with what remains.
        let didClear = await settings.storage.clearWebReaderCache()
        XCTAssertFalse(didClear)
        let novelBytes = await fixture.novelReaderCacheStore.totalDiskUsageBytes()
        let forumBytes = await fixture.forumCacheStore.totalDiskUsageBytes()
        XCTAssertEqual(novelBytes, 0)
        XCTAssertEqual(settings.storage.webReaderCacheBytes, forumBytes)
        XCTAssertNotNil(settings.storage.errorMessage)
    }

    func testStorageSizeFormattingAdaptsUnitsAndNeverRoundsSmallDataToZero() {
        for bytes in [0, 1, 512, 1000, 1_000_000, 1_000_000_000] {
            XCTAssertEqual(SettingsStorageUsage.cacheLabel(for: bytes), cacheLabel(for: bytes))
        }
        XCTAssertEqual(SettingsStorageUsage.cacheLabel(for: -1), cacheLabel(for: 0))
        XCTAssertNotEqual(SettingsStorageUsage.cacheLabel(for: 1), SettingsStorageUsage.cacheLabel(for: 0))
        XCTAssertTrue(SettingsStorageUsage.cacheLabel(for: 1000).contains("KB"))
        XCTAssertTrue(SettingsStorageUsage.cacheLabel(for: 1_000_000).contains("MB"))
        XCTAssertTrue(SettingsStorageUsage.cacheLabel(for: 1_000_000_000).contains("GB"))
    }
}

private func cacheLabel(for bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: Int64(max(0, bytes)))
}

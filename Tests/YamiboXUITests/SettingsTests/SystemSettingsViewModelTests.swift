import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class SystemSettingsViewModelTests: XCTestCase {
    func testLoadReadsApplePencilPageTurnSettings() async throws {
        let fixture = try makeFixture()
        let savedSettings = ApplePencilPageTurnSettings(
            isEnabled: true,
            behavior: .doubleTapNextSqueezePrevious
        )
        try await fixture.settingsStore.save(AppSettings(system: SystemSettings(applePencilPageTurn: savedSettings)))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()

        XCTAssertEqual(viewModel.applePencilPageTurn, savedSettings)
    }

    func testLoadReadsNovelOfflineCacheSettings() async throws {
        let fixture = try makeFixture()
        let savedSettings = NovelOfflineCacheSettings(
            retainsInlineImages: true,
            isAutoRefreshEnabled: false
        )
        try await fixture.settingsStore.save(AppSettings(novelOfflineCache: savedSettings))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()

        XCTAssertEqual(viewModel.novelOfflineCache, savedSettings)
    }

    func testLoadReadsFavoriteBackgroundSettings() async throws {
        let fixture = try makeFixture()
        let savedSettings = FavoriteBackgroundSettings(
            isEnabled: true,
            imageID: "background",
            scale: 1.7,
            offsetX: 0.2,
            offsetY: -0.3,
            blurRadius: 11
        )
        try await fixture.settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(background: savedSettings)))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()

        XCTAssertEqual(viewModel.favoriteBackground, savedSettings)
    }

    func testFavoriteLibraryDisplaySettingsLoadAndPersist() async throws {
        let fixture = try makeFixture()
        try await fixture.settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(
            layoutMode: .staggered,
            sortOrder: .displayTitle,
            sortDescending: true,
            showsCategoryCounts: false
        )))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()

        XCTAssertEqual(viewModel.favoriteLayoutMode, .staggered)
        XCTAssertEqual(viewModel.favoriteSortOrder, .displayTitle)
        XCTAssertTrue(viewModel.favoriteSortDescending)
        XCTAssertFalse(viewModel.favoriteShowsCategoryCounts)

        viewModel.updateFavoriteLayoutMode(.fixedGrid)
        viewModel.updateFavoriteSortOrder(.lastReadAt)
        viewModel.updateFavoriteSortDescending(false)
        viewModel.updateFavoriteShowsCategoryCounts(true)

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.favorites.layoutMode == .fixedGrid
                && loaded.favorites.sortOrder == .lastReadAt
                && !loaded.favorites.sortDescending
                && loaded.favorites.showsCategoryCounts
        }
        XCTAssertEqual(viewModel.favoriteLayoutMode, .fixedGrid)
        XCTAssertEqual(viewModel.favoriteSortOrder, .lastReadAt)
        XCTAssertFalse(viewModel.favoriteSortDescending)
        XCTAssertTrue(viewModel.favoriteShowsCategoryCounts)
    }

    func testFavoriteSmartMangaBulkDeleteSettingLoadsAndPersists() async throws {
        let fixture = try makeFixture()
        try await fixture.settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(
            smartMangaBulkDeleteEnabled: false
        )))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()

        XCTAssertFalse(viewModel.favoriteSmartMangaBulkDeleteEnabled)

        viewModel.updateFavoriteSmartMangaBulkDeleteEnabled(true)

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.favorites.smartMangaBulkDeleteEnabled
        }
        XCTAssertTrue(viewModel.favoriteSmartMangaBulkDeleteEnabled)
    }

    func testApplyFavoriteBackgroundPersistsImageAndSettings() async throws {
        let fixture = try makeFixture()
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        let imageData = Data(repeating: 6, count: 128)
        let draftSettings = FavoriteBackgroundSettings(
            isEnabled: true,
            scale: 2,
            offsetX: 0.5,
            offsetY: -0.25,
            blurRadius: 14
        )

        let didApply = await viewModel.applyFavoriteBackground(
            imageData: imageData,
            draftSettings: draftSettings
        )

        XCTAssertTrue(didApply)
        let loaded = await fixture.settingsStore.load()
        let imageID = try XCTUnwrap(loaded.favorites.background.imageID)
        XCTAssertTrue(loaded.favorites.background.isEnabled)
        XCTAssertEqual(loaded.favorites.background.scale, 2)
        XCTAssertEqual(loaded.favorites.background.offsetX, 0.5)
        XCTAssertEqual(loaded.favorites.background.offsetY, -0.25)
        XCTAssertEqual(loaded.favorites.background.blurRadius, 14)
        let savedImageData = await fixture.favoriteBackgroundImageStore.loadData(imageID: imageID)
        XCTAssertEqual(savedImageData, imageData)
        XCTAssertEqual(viewModel.favoriteBackground, loaded.favorites.background)
    }

    func testRestoreDefaultFavoriteBackgroundClearsImageAndSettings() async throws {
        let fixture = try makeFixture()
        let imageID = "background"
        try await fixture.favoriteBackgroundImageStore.save(Data(repeating: 7, count: 96), imageID: imageID)
        try await fixture.settingsStore.save(AppSettings(
            favorites: FavoriteLibrarySettings(background: FavoriteBackgroundSettings(isEnabled: true, imageID: imageID))
        ))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        let didRestore = await viewModel.restoreDefaultFavoriteBackground()

        XCTAssertTrue(didRestore)
        XCTAssertEqual(viewModel.favoriteBackground, FavoriteBackgroundSettings())
        let loadedSettings = await fixture.settingsStore.load()
        XCTAssertEqual(loadedSettings.favorites.background, FavoriteBackgroundSettings())
        let savedImageData = await fixture.favoriteBackgroundImageStore.loadData(imageID: imageID)
        XCTAssertNil(savedImageData)
    }

    func testUpdateApplePencilEnabledPersistsSettings() async throws {
        let fixture = try makeFixture()
        try await fixture.settingsStore.save(AppSettings())

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        viewModel.updateApplePencilPageTurnEnabled(true)

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.system.applePencilPageTurn.isEnabled
        }
        XCTAssertTrue(viewModel.applePencilPageTurn.isEnabled)
    }

    func testUpdateApplePencilBehaviorPersistsSettings() async throws {
        let fixture = try makeFixture()
        try await fixture.settingsStore.save(AppSettings())

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        viewModel.updateApplePencilPageTurnBehavior(.doubleTapNextSqueezePrevious)

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.system.applePencilPageTurn.behavior == .doubleTapNextSqueezePrevious
        }
        XCTAssertEqual(viewModel.applePencilPageTurn.behavior, .doubleTapNextSqueezePrevious)
    }

    func testUpdateNovelOfflineCacheSettingsPersistsSettings() async throws {
        let fixture = try makeFixture()
        try await fixture.settingsStore.save(AppSettings())

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        XCTAssertFalse(viewModel.novelOfflineCache.retainsInlineImages)
        XCTAssertTrue(viewModel.novelOfflineCache.isAutoRefreshEnabled)

        viewModel.updateNovelOfflineCacheRetainsInlineImages(true)
        try await waitFor {
            await fixture.settingsStore.load().novelOfflineCache.retainsInlineImages
        }
        viewModel.updateNovelOfflineCacheAutoRefreshEnabled(false)

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.novelOfflineCache == NovelOfflineCacheSettings(
                retainsInlineImages: true,
                isAutoRefreshEnabled: false
            )
        }
        XCTAssertEqual(viewModel.novelOfflineCache, NovelOfflineCacheSettings(
            retainsInlineImages: true,
            isAutoRefreshEnabled: false
        ))
    }

    /// The Settings screen's read side: loading the persisted per-board
    /// reader configuration into the view model.
    func testLoadReadsBoardReaderSettings() async throws {
        let fixture = try makeFixture()
        var seeded = BoardReaderSettings()
        seeded.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "30")
        seeded.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
        try await fixture.settingsStore.save(AppSettings(boardReader: seeded))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()

        XCTAssertFalse(viewModel.boardReader.isSmartComicModeEnabled(forumID: "30"))
        XCTAssertTrue(viewModel.boardReader.isSmartComicModeEnabled(forumID: "46"))
        XCTAssertFalse(viewModel.boardReader.isSmartComicModeEnabled(forumID: "37"))
    }

    /// The overview's smart-bit write side: flipping fid 30 off and fid 46
    /// on persists through `SettingsStore`, exercised independently for both
    /// directions (enabling and disabling) on two different
    /// manga-configured boards.
    func testSetBoardReaderModeFlipsSmartBitAndPersistsSettings() async throws {
        let fixture = try makeFixture()
        try await fixture.settingsStore.save(AppSettings())

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        XCTAssertTrue(viewModel.boardReader.isSmartComicModeEnabled(forumID: "30"))
        XCTAssertFalse(viewModel.boardReader.isSmartComicModeEnabled(forumID: "46"))

        viewModel.setBoardReaderMode(.manga(smartEnabled: false), forumID: "30", boardName: "中文百合漫画区")
        viewModel.setBoardReaderMode(.manga(smartEnabled: true), forumID: "46", boardName: nil)

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return !loaded.boardReader.isSmartComicModeEnabled(forumID: "30")
                && loaded.boardReader.isSmartComicModeEnabled(forumID: "46")
        }
        XCTAssertFalse(viewModel.boardReader.isSmartComicModeEnabled(forumID: "30"))
        XCTAssertTrue(viewModel.boardReader.isSmartComicModeEnabled(forumID: "46"))
        let loaded = await fixture.settingsStore.load()
        XCTAssertEqual(loaded.boardReader.entry(forumID: "30")?.boardName, "中文百合漫画区")
    }

    /// Changing a board's mode from the overview overwrites the entry while
    /// carrying the stored name snapshot through unchanged (the central
    /// settings page never resolves real board names).
    func testSetBoardReaderModePersistsModeChangeAndKeepsNameSnapshot() async throws {
        let fixture = try makeFixture()
        var seeded = BoardReaderSettings()
        seeded.setEntry(.init(mode: .manga(smartEnabled: true), boardName: "中文百合漫画区"), forumID: "30")
        try await fixture.settingsStore.save(AppSettings(boardReader: seeded))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        viewModel.setBoardReaderMode(.novel, forumID: "30", boardName: "中文百合漫画区")

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.boardReader.entry(forumID: "30")?.mode == .novel
        }
        let loaded = await fixture.settingsStore.load()
        XCTAssertEqual(
            loaded.boardReader.entry(forumID: "30"),
            BoardReaderSettings.Entry(mode: .novel, boardName: "中文百合漫画区")
        )
        XCTAssertEqual(viewModel.boardReader.entry(forumID: "30")?.mode, .novel)
    }

    /// The row menu's 普通 option overwrites the entry with an explicit
    /// `.normal` mode (pluggable-reader-config R12) — the entry stays listed
    /// with its name snapshot, and the other configured boards are untouched.
    func testSetBoardReaderModeNormalPersistsExplicitEntry() async throws {
        let fixture = try makeFixture()
        try await fixture.settingsStore.save(AppSettings())

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        XCTAssertNotNil(viewModel.boardReader.entry(forumID: "49"))

        viewModel.setBoardReaderMode(.normal, forumID: "49", boardName: "小说板块")

        let expected = BoardReaderSettings.Entry(mode: .normal, boardName: "小说板块")
        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.boardReader.entry(forumID: "49") == expected
        }
        XCTAssertEqual(viewModel.boardReader.entry(forumID: "49"), expected)
        let loaded = await fixture.settingsStore.load()
        XCTAssertEqual(loaded.boardReader.entry(forumID: "55")?.mode, .novel)
        XCTAssertTrue(loaded.boardReader.isSmartComicModeEnabled(forumID: "30"))
    }

    /// The overview's "恢复默认配置" action: any customized configuration
    /// snaps back to the factory default.
    func testResetBoardReaderRestoresFactoryDefault() async throws {
        let fixture = try makeFixture()
        var customized = BoardReaderSettings(entries: [:])
        customized.setEntry(.init(mode: .novel, boardName: "自定义板块"), forumID: "99")
        try await fixture.settingsStore.save(AppSettings(boardReader: customized))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        XCTAssertEqual(viewModel.boardReader, customized)

        viewModel.resetBoardReader()

        try await waitFor {
            let loaded = await fixture.settingsStore.load()
            return loaded.boardReader == .factoryDefault
        }
        XCTAssertEqual(viewModel.boardReader, .factoryDefault)
    }

    func testResetApplicationRestoresDefaultApplePencilSettings() async throws {
        let fixture = try makeFixture()
        try await fixture.settingsStore.save(AppSettings(
            novelOfflineCache: NovelOfflineCacheSettings(
                retainsInlineImages: true,
                isAutoRefreshEnabled: false
            ),
            system: SystemSettings(applePencilPageTurn: ApplePencilPageTurnSettings(
                isEnabled: true,
                behavior: .doubleTapNextSqueezePrevious
            )),
            boardReader: {
                var custom = BoardReaderSettings()
                custom.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
                custom.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "37")
                custom.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "30")
                return custom
            }()
        ))

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
        let didReset = await viewModel.resetApplication()

        XCTAssertTrue(didReset)
        XCTAssertEqual(viewModel.novelOfflineCache, NovelOfflineCacheSettings())
        XCTAssertEqual(viewModel.applePencilPageTurn, ApplePencilPageTurnSettings())
        XCTAssertEqual(viewModel.boardReader, BoardReaderSettings())
        let loaded = await fixture.settingsStore.load()
        XCTAssertEqual(loaded.novelOfflineCache, NovelOfflineCacheSettings())
        XCTAssertEqual(loaded.system.applePencilPageTurn, ApplePencilPageTurnSettings())
        XCTAssertEqual(viewModel.favoriteBackground, FavoriteBackgroundSettings())
    }

    func testLoadReadsStorageUsageAcrossAllCacheCategories() async throws {
        let fixture = try makeFixture()
        try await seedNovelCache(fixture)
        try await seedMangaIndexCache(fixture)
        try await seedForumCache(fixture)
        try await seedContentCover(fixture)
        try await seedMangaOfflineCache(fixture)

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()

        XCTAssertGreaterThan(viewModel.webReaderCacheBytes, 0)
        XCTAssertGreaterThan(viewModel.contentCoverCacheBytes, 0)
        XCTAssertGreaterThan(viewModel.mangaDirectoryCacheBytes, 0)
        XCTAssertGreaterThan(viewModel.offlineCacheBytes, 0)
        XCTAssertEqual(viewModel.webReaderCacheLabel, cacheLabel(for: viewModel.webReaderCacheBytes))
        XCTAssertEqual(viewModel.contentCoverCacheLabel, cacheLabel(for: viewModel.contentCoverCacheBytes))
        XCTAssertEqual(viewModel.mangaDirectoryCacheLabel, cacheLabel(for: viewModel.mangaDirectoryCacheBytes))
        XCTAssertEqual(viewModel.offlineCacheLabel, cacheLabel(for: viewModel.offlineCacheBytes))
    }

    func testClearWebReaderCacheClearsNovelMangaProjectionAndForumCacheOnly() async throws {
        let fixture = try makeFixture()
        try await seedNovelCache(fixture)
        try await seedMangaIndexCache(fixture)
        try await seedForumCache(fixture)
        try await seedMangaOfflineCache(fixture)

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
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
        let fixture = try makeFixture()
        try await seedContentCover(fixture)
        try await seedNovelCache(fixture)

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
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
        let fixture = try makeFixture()
        let session = makeAuthenticatedSession()
        await fixture.appContext.checkInStore.markCheckedIn(session: session)
        try await seedFavoriteUpdateStoreState(fixture)
        try await seedNovelCache(fixture)

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
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
    }

    func testClearImageCachePreservesReaderAndUserOwnedCaches() async throws {
        let fixture = try makeFixture()
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

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
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

    func testOfflineCacheManagementFiltersOwnersWithMembershipOrWorkAndShowsUsage() async throws {
        let fixture = try makeFixture()
        let membershipImage = try XCTUnwrap(URL(string: "https://img.example.com/offline-a.jpg"))
        let workImage = try XCTUnwrap(URL(string: "https://img.example.com/offline-b.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data(repeating: 1, count: 4), for: membershipImage)
        try await fixture.offlineCacheStore.saveOfflineImageData(Data(repeating: 2, count: 7), for: workImage)
        let membership = try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [membershipImage])
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(membership)
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeMangaOfflineWorkRequest(ownerName: "作品B", tid: "320", targetImageURLs: [workImage])
        )
        try await fixture.offlineCacheStore.updateOfflineCacheWorkProgress(
            ownerName: "作品B",
            tid: "320",
            targetImageURLs: [workImage],
            completedImageURLs: [workImage],
            currentBytesPerSecond: nil
        )
        try await fixture.offlineCacheStore.saveNovelOfflineCacheEntry(
            try makeNovelOfflineCacheEntry(ownerTitle: "小说A", tid: "410", view: 1)
        )

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        let groupsByID = Dictionary(
            uniqueKeysWithValues: viewModel.offlineCacheManagementRows.map { ($0.id, $0) }
        )
        let novelGroupID = try novelOfflineEntryID(ownerTitle: "小说A", tid: "410", view: 1).groupID
        let cachedMangaGroup = groupsByID[OfflineCacheGroupID(readerKind: .manga, ownerKey: "作品A")]
        let pendingMangaGroup = groupsByID[OfflineCacheGroupID(readerKind: .manga, ownerKey: "作品B")]
        let novelGroup = groupsByID[novelGroupID]
        let expectedMangaBytes = try JSONEncoder().encode(membership.sourcePage).count + 4
        XCTAssertEqual(cachedMangaGroup?.title, "作品A")
        XCTAssertEqual(cachedMangaGroup?.byteCount, expectedMangaBytes)
        XCTAssertEqual(pendingMangaGroup?.title, "作品B")
        XCTAssertEqual(pendingMangaGroup?.byteCount, 7)
        XCTAssertEqual(novelGroup?.title, "小说A")
        XCTAssertEqual(novelGroup?.entries.count, 1)
        XCTAssertGreaterThan(novelGroup?.byteCount ?? 0, 0)
        XCTAssertFalse(viewModel.offlineCacheManagementIsEmpty)
    }

    func testOfflineCacheManagementEmptyStateWhenNoMembershipOrWorkExists() async throws {
        let fixture = try makeFixture()
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)

        await viewModel.refreshOfflineCacheManagement()

        XCTAssertTrue(viewModel.offlineCacheManagementRows.isEmpty)
        XCTAssertTrue(viewModel.offlineCacheManagementIsEmpty)
    }

    func testOfflineCacheManagementSingleAndSwipeDeletePrepareConfirmation() async throws {
        let fixture = try makeFixture()
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/offline-single.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [imageURL])
        )
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        viewModel.requestOfflineCacheGroupDeletion(id: mangaOfflineGroupID("作品A"))
        XCTAssertEqual(viewModel.pendingOfflineCacheManagementConfirmation?.groupIDs.map(\.ownerKey), ["作品A"])

        viewModel.cancelOfflineCacheManagementConfirmation()
        viewModel.requestOfflineCacheSwipeGroupDeletion(id: mangaOfflineGroupID("作品A"))
        XCTAssertEqual(viewModel.pendingOfflineCacheManagementConfirmation?.groupIDs.map(\.ownerKey), ["作品A"])
    }

    func testOfflineCacheManagementBatchDeleteUsesOneConfirmationForSelectedOwners() async throws {
        let fixture = try makeFixture()
        let firstImage = try XCTUnwrap(URL(string: "https://img.example.com/offline-batch-1.jpg"))
        let secondImage = try XCTUnwrap(URL(string: "https://img.example.com/offline-batch-2.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: firstImage)
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([2]), for: secondImage)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [firstImage])
        )
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品B", tid: "320", imageURLs: [secondImage])
        )
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        viewModel.setOfflineCacheManagementSelectionMode(true)
        viewModel.toggleOfflineCacheManagementSelection(id: mangaOfflineGroupID("作品A"))
        viewModel.toggleOfflineCacheManagementSelection(id: mangaOfflineGroupID("作品B"))
        viewModel.requestSelectedOfflineCacheGroupDeletion()

        XCTAssertEqual(viewModel.pendingOfflineCacheManagementConfirmation?.groupIDs.map(\.ownerKey), ["作品A", "作品B"])
    }

    func testOfflineCacheManagementSelectionActionStateEnablesDeleteWhenOwnerIsSelected() async throws {
        let fixture = try makeFixture()
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/offline-selection-state.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [imageURL])
        )
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        viewModel.setOfflineCacheManagementSelectionMode(true)
        XCTAssertEqual(
            viewModel.offlineCacheManagementSelectionActionState,
            OfflineCacheManagementSelectionActionState(selectedGroupCount: 0, canDelete: false)
        )

        viewModel.toggleOfflineCacheManagementSelection(id: mangaOfflineGroupID("作品A"))
        XCTAssertEqual(
            viewModel.offlineCacheManagementSelectionActionState,
            OfflineCacheManagementSelectionActionState(selectedGroupCount: 1, canDelete: true)
        )

        viewModel.toggleOfflineCacheManagementSelection(id: mangaOfflineGroupID("作品A"))
        XCTAssertEqual(
            viewModel.offlineCacheManagementSelectionActionState,
            OfflineCacheManagementSelectionActionState(selectedGroupCount: 0, canDelete: false)
        )
    }

    func testOfflineCacheManagementConfirmDeletesMembershipsWorksAndUnsharedOfflineBytes() async throws {
        let fixture = try makeFixture()
        let removedImage = try XCTUnwrap(URL(string: "https://img.example.com/remove.jpg"))
        let sharedImage = try XCTUnwrap(URL(string: "https://img.example.com/shared.jpg"))
        let workImage = try XCTUnwrap(URL(string: "https://img.example.com/work.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: removedImage)
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([2]), for: sharedImage)
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([3]), for: workImage)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [removedImage, sharedImage])
        )
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品B", tid: "320", imageURLs: [sharedImage])
        )
        _ = try await fixture.offlineCacheStore.enqueueMangaOfflineCacheWork(
            try makeMangaOfflineWorkRequest(ownerName: "作品A", tid: "311", targetImageURLs: [workImage])
        )
        try await fixture.offlineCacheStore.updateOfflineCacheWorkProgress(
            ownerName: "作品A",
            tid: "311",
            targetImageURLs: [workImage],
            completedImageURLs: [workImage],
            currentBytesPerSecond: nil
        )
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        viewModel.requestOfflineCacheGroupDeletion(id: mangaOfflineGroupID("作品A"))
        let didDelete = await viewModel.confirmPendingOfflineCacheManagementDeletion()

        let removedMembership = await fixture.offlineCacheStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "310")
        let removedWork = await fixture.offlineCacheStore.mangaQueueWork(ownerName: "作品A", tid: "311")
        let removedImageData = await fixture.offlineCacheStore.offlineImageData(for: removedImage)
        let workImageData = await fixture.offlineCacheStore.offlineImageData(for: workImage)
        let sharedImageData = await fixture.offlineCacheStore.offlineImageData(for: sharedImage)

        XCTAssertTrue(didDelete)
        XCTAssertNil(removedMembership)
        XCTAssertNil(removedWork)
        XCTAssertNil(removedImageData)
        XCTAssertNil(workImageData)
        XCTAssertEqual(sharedImageData, Data([2]))
        XCTAssertEqual(viewModel.offlineCacheManagementRows.map(\.id.ownerKey), ["作品B"])
        XCTAssertFalse(viewModel.isOfflineCacheManagementSelectionMode)
        XCTAssertTrue(viewModel.selectedOfflineCacheGroupIDs.isEmpty)
    }

    func testOfflineCacheManagementEntryDeletionDeletesOnlySelectedEntry() async throws {
        let fixture = try makeFixture()
        let firstImage = try XCTUnwrap(URL(string: "https://img.example.com/entry-310.jpg"))
        let secondImage = try XCTUnwrap(URL(string: "https://img.example.com/entry-311.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: firstImage)
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([2]), for: secondImage)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [firstImage])
        )
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "311", imageURLs: [secondImage])
        )
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        viewModel.requestOfflineCacheEntryDeletion(id: mangaOfflineEntryID(ownerName: "作品A", tid: "310"))
        let didDelete = await viewModel.confirmPendingOfflineCacheManagementDeletion()

        let removedMembership = await fixture.offlineCacheStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "310")
        let retainedMembership = await fixture.offlineCacheStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "311")
        let removedImageData = await fixture.offlineCacheStore.offlineImageData(for: firstImage)
        let retainedImageData = await fixture.offlineCacheStore.offlineImageData(for: secondImage)

        XCTAssertTrue(didDelete)
        XCTAssertNil(removedMembership)
        XCTAssertNotNil(retainedMembership)
        XCTAssertNil(removedImageData)
        XCTAssertEqual(retainedImageData, Data([2]))
        XCTAssertEqual(viewModel.offlineCacheManagementRows.map(\.id.ownerKey), ["作品A"])
        XCTAssertEqual(viewModel.offlineCacheManagementRows.first?.entries.map(\.id.entryKey), ["311"])
    }

    func testOfflineCacheManagementDeletesNovelGroupAndIndividualView() async throws {
        let fixture = try makeFixture()
        try await fixture.offlineCacheStore.saveNovelOfflineCacheEntry(
            try makeNovelOfflineCacheEntry(ownerTitle: "小说A", tid: "410", view: 1)
        )
        try await fixture.offlineCacheStore.saveNovelOfflineCacheEntry(
            try makeNovelOfflineCacheEntry(ownerTitle: "小说A", tid: "410", view: 2)
        )
        try await fixture.offlineCacheStore.saveNovelOfflineCacheEntry(
            try makeNovelOfflineCacheEntry(ownerTitle: "小说B", tid: "420", view: 1)
        )
        let firstEntryID = try novelOfflineEntryID(tid: "410", view: 1)
        let secondEntryID = try novelOfflineEntryID(tid: "410", view: 2)
        let firstGroupID = firstEntryID.groupID
        let otherGroupID = try novelOfflineEntryID(ownerTitle: "小说B", tid: "420", view: 1).groupID
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        viewModel.requestOfflineCacheEntryDeletion(id: firstEntryID)
        let didDeleteEntry = await viewModel.confirmPendingOfflineCacheManagementDeletion()

        XCTAssertTrue(didDeleteEntry)
        let removedEntry = await fixture.offlineCacheStore.novelOfflineCacheEntry(id: firstEntryID)
        let retainedEntry = await fixture.offlineCacheStore.novelOfflineCacheEntry(id: secondEntryID)
        XCTAssertNil(removedEntry)
        XCTAssertNotNil(retainedEntry)
        XCTAssertEqual(viewModel.offlineCacheManagementRows.first { $0.id == firstGroupID }?.title, "小说A")
        XCTAssertEqual(viewModel.offlineCacheManagementRows.first { $0.id == firstGroupID }?.entries.count, 1)

        viewModel.requestOfflineCacheGroupDeletion(id: firstGroupID)
        let didDeleteGroup = await viewModel.confirmPendingOfflineCacheManagementDeletion()

        XCTAssertTrue(didDeleteGroup)
        let removedGroupEntry = await fixture.offlineCacheStore.novelOfflineCacheEntry(id: secondEntryID)
        XCTAssertNil(removedGroupEntry)
        XCTAssertEqual(viewModel.offlineCacheManagementRows.map(\.id.ownerKey), [otherGroupID.ownerKey])
        XCTAssertEqual(viewModel.offlineCacheManagementRows.map(\.title), ["小说B"])
    }

    func testOfflineCacheManagementConfirmUsesCapturedConfirmationAfterPendingDismissal() async throws {
        let fixture = try makeFixture()
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/dismiss-race.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [imageURL])
        )
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        viewModel.requestOfflineCacheGroupDeletion(id: mangaOfflineGroupID("作品A"))
        let confirmation = try XCTUnwrap(viewModel.pendingOfflineCacheManagementConfirmation)
        viewModel.cancelOfflineCacheManagementConfirmation()
        let didDelete = await viewModel.confirmOfflineCacheManagementDeletion(confirmation)

        let removedMembership = await fixture.offlineCacheStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "310")
        XCTAssertTrue(didDelete)
        XCTAssertNil(removedMembership)
        XCTAssertTrue(viewModel.offlineCacheManagementRows.isEmpty)
    }

    func testOfflineCacheManagementPreservesMangaIndexCaches() async throws {
        let fixture = try makeFixture()
        try await seedMangaIndexCache(fixture)
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/901-1.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "901", imageURLs: [imageURL])
        )
        let directoryBytesBeforeClear = await fixture.mangaDirectoryStore.totalDiskUsageBytes()
        let projectionBytesBeforeClear = await fixture.mangaReaderProjectionStore.totalDiskUsageBytes()
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshOfflineCacheManagement()

        viewModel.requestOfflineCacheGroupDeletion(id: mangaOfflineGroupID("作品A"))
        let didDelete = await viewModel.confirmPendingOfflineCacheManagementDeletion()

        let directoryBytesAfterClear = await fixture.mangaDirectoryStore.totalDiskUsageBytes()
        let projectionBytesAfterClear = await fixture.mangaReaderProjectionStore.totalDiskUsageBytes()

        XCTAssertTrue(didDelete)
        XCTAssertEqual(directoryBytesAfterClear, directoryBytesBeforeClear)
        XCTAssertEqual(projectionBytesAfterClear, projectionBytesBeforeClear)
    }

    func testResetApplicationClearsStorageUsageCounters() async throws {
        let fixture = try makeFixture()
        try await seedNovelCache(fixture)
        try await seedMangaIndexCache(fixture)
        try await seedMangaOfflineCache(fixture)

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.load()
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
        XCTAssertEqual(offlineBytesAfterReset, 0)
        XCTAssertNil(offlineMembershipAfterReset)
    }

    /// Regression test for the bug where `resetApplicationData()` claimed to
    /// wipe "全部缓存" but never actually cleared the per-account check-in
    /// date cache or the favorites-update tracking state (tracked targets,
    /// detected events, run history, fid/category filters).
    func testResetApplicationClearsCheckInAndFavoriteUpdateStores() async throws {
        let fixture = try makeFixture()
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

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let didReset = await viewModel.resetApplication()

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

    func testMangaDirectoryManagementListsDirectoriesWithChapterCounts() async throws {
        let fixture = try makeFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101", "102"])
        try await seedMangaDirectory(fixture, cleanBookName: "作品B", chapterTIDs: ["201"])

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshMangaDirectoryManagement()

        let rowsByTitle = Dictionary(uniqueKeysWithValues: viewModel.mangaDirectoryManagementRows.map { ($0.title, $0) })
        XCTAssertEqual(rowsByTitle["作品A"]?.chapterCount, 2)
        XCTAssertEqual(rowsByTitle["作品B"]?.chapterCount, 1)
        XCTAssertFalse(viewModel.mangaDirectoryManagementIsEmpty)
    }

    func testMangaDirectoryManagementSingleDeletePreparesConfirmation() async throws {
        let fixture = try makeFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101"])
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshMangaDirectoryManagement()

        viewModel.requestMangaDirectoryDeletion(id: "作品A")
        XCTAssertEqual(viewModel.pendingMangaDirectoryManagementConfirmation?.directoryIDs, ["作品A"])

        viewModel.cancelMangaDirectoryManagementConfirmation()
        XCTAssertNil(viewModel.pendingMangaDirectoryManagementConfirmation)
    }

    func testMangaDirectoryManagementBatchDeleteUsesOneConfirmationForSelectedDirectories() async throws {
        let fixture = try makeFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101"])
        try await seedMangaDirectory(fixture, cleanBookName: "作品B", chapterTIDs: ["201"])
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshMangaDirectoryManagement()

        viewModel.setMangaDirectoryManagementSelectionMode(true)
        viewModel.toggleMangaDirectoryManagementSelection(id: "作品A")
        viewModel.toggleMangaDirectoryManagementSelection(id: "作品B")
        viewModel.requestSelectedMangaDirectoryDeletion()

        XCTAssertEqual(viewModel.pendingMangaDirectoryManagementConfirmation?.directoryIDs, ["作品A", "作品B"])
    }

    func testMangaDirectoryManagementConfirmDeletesOnlySelectedDirectories() async throws {
        let fixture = try makeFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101"])
        try await seedMangaDirectory(fixture, cleanBookName: "作品B", chapterTIDs: ["201"])
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshMangaDirectoryManagement()

        viewModel.requestMangaDirectoryDeletion(id: "作品A")
        let didDelete = await viewModel.confirmPendingMangaDirectoryManagementDeletion()

        let removedDirectory = try await fixture.mangaDirectoryStore.directory(named: "作品A")
        let retainedDirectory = try await fixture.mangaDirectoryStore.directory(named: "作品B")

        XCTAssertTrue(didDelete)
        XCTAssertNil(removedDirectory)
        XCTAssertNotNil(retainedDirectory)
        XCTAssertEqual(viewModel.mangaDirectoryManagementRows.map(\.title), ["作品B"])
        XCTAssertFalse(viewModel.isMangaDirectoryManagementSelectionMode)
        XCTAssertTrue(viewModel.selectedMangaDirectoryIDs.isEmpty)
    }

    /// The directory index and offline downloads/favorite-update tracking
    /// for the same book are independent stores with no FK/cascade between
    /// them — deleting the index entry must not silently wipe either.
    func testMangaDirectoryDeletionDoesNotTouchOfflineCacheOrFavoriteUpdateTracking() async throws {
        let fixture = try makeFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["310"])
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/directory-delete-310.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [imageURL])
        )
        try await fixture.appContext.favoriteUpdateStore.upsertTrackedTarget(
            makeMangaDirectoryTrackedTarget(cleanBookName: "作品A")
        )

        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshMangaDirectoryManagement()

        viewModel.requestMangaDirectoryDeletion(id: "作品A")
        let didDelete = await viewModel.confirmPendingMangaDirectoryManagementDeletion()

        let removedDirectory = try await fixture.mangaDirectoryStore.directory(named: "作品A")
        let membershipAfterDelete = await fixture.offlineCacheStore.mangaOfflineCacheMembership(ownerName: "作品A", tid: "310")
        let stateAfterDelete = await fixture.appContext.favoriteUpdateStore.loadState()

        XCTAssertTrue(didDelete)
        XCTAssertNil(removedDirectory)
        XCTAssertNotNil(membershipAfterDelete)
        XCTAssertFalse(stateAfterDelete.trackedTargets.isEmpty)
    }

    /// "Select all" then delete is how the two-level menu supports clearing
    /// every directory, mirroring offline cache management's select-all flow
    /// rather than adding a second, separate destructive action.
    func testMangaDirectoryManagementSelectAllThenDeleteClearsAllDirectories() async throws {
        let fixture = try makeFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101"])
        try await seedMangaDirectory(fixture, cleanBookName: "作品B", chapterTIDs: ["201"])
        let viewModel = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await viewModel.refreshMangaDirectoryManagement()

        viewModel.setMangaDirectoryManagementSelectionMode(true)
        viewModel.toggleAllMangaDirectoryManagementRows()
        XCTAssertTrue(viewModel.isMangaDirectoryManagementSelectionComplete)

        // Toggling again while fully selected must deselect everything
        // (the method's other branch) rather than being a no-op.
        viewModel.toggleAllMangaDirectoryManagementRows()
        XCTAssertTrue(viewModel.selectedMangaDirectoryIDs.isEmpty)
        XCTAssertFalse(viewModel.isMangaDirectoryManagementSelectionComplete)

        viewModel.toggleAllMangaDirectoryManagementRows()
        XCTAssertTrue(viewModel.isMangaDirectoryManagementSelectionComplete)

        viewModel.requestSelectedMangaDirectoryDeletion()
        let didDelete = await viewModel.confirmPendingMangaDirectoryManagementDeletion()

        XCTAssertTrue(didDelete)
        XCTAssertTrue(viewModel.mangaDirectoryManagementRows.isEmpty)
        XCTAssertTrue(viewModel.mangaDirectoryManagementIsEmpty)
        let directoryBytesAfterClear = await fixture.mangaDirectoryStore.totalDiskUsageBytes()
        XCTAssertEqual(directoryBytesAfterClear, 0)
    }
}

private struct SystemSettingsFixture {
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

private func makeFixture() throws -> SystemSettingsFixture {
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

private func mangaOfflineGroupID(_ ownerName: String) -> OfflineCacheGroupID {
    OfflineCacheGroupID(readerKind: .manga, ownerKey: ownerName)
}

private func mangaOfflineEntryID(ownerName: String, tid: String) -> OfflineCacheEntryID {
    OfflineCacheEntryID(readerKind: .manga, ownerKey: ownerName, entryKey: tid)
}

private func novelOfflineEntryID(
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

private final class RecordingOrdinaryImageCache: YamiboOrdinaryImageCacheClearing, @unchecked Sendable {
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

private func makeNovelOfflineCacheEntry(
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

private func seedNovelCache(_ fixture: SystemSettingsFixture) async throws {
    try await fixture.novelReaderCacheStore.save(
        NovelReaderProjection(
            threadID: "900",
            view: 1,
            maxView: 1,
            segments: [.text("测试小说缓存", chapterTitle: nil)]
        )
    )
}

private func seedMangaIndexCache(_ fixture: SystemSettingsFixture) async throws {
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

private func seedForumCache(_ fixture: SystemSettingsFixture) async throws {
    try await fixture.forumCacheStore.saveThreadPage(
        makeSystemSettingsOfflineSourcePage(tid: "950"),
        thread: ThreadIdentity(tid: "950")
    )
}

private func seedContentCover(_ fixture: SystemSettingsFixture) async throws {
    _ = try await fixture.appContext.contentCoverStore.setAutomaticCover(
        try XCTUnwrap(URL(string: "https://img.example.com/cover.jpg")),
        for: .smartManga(cleanBookName: "测试漫画")
    )
}

private func seedMangaDirectory(
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

private func makeAuthenticatedSession() -> SessionState {
    SessionState(cookie: "\(SessionState.authenticationCookieName)=settings-test-account", isLoggedIn: true)
}

private func makeMangaDirectoryTrackedTarget(cleanBookName: String) -> FavoriteUpdateTrackedTarget {
    FavoriteUpdateTrackedTarget(
        target: .mangaDirectory(cleanBookName: cleanBookName),
        title: cleanBookName,
        mode: .mangaDirectory
    )
}

/// Populates all 5 tables `FavoriteUpdateStore.clearAll()` touches (tracked
/// targets, events, runs, fid filters, category filters) so tests can assert
/// every one of them is actually wiped, not just the tracked-targets table.
private func seedFavoriteUpdateStoreState(_ fixture: SystemSettingsFixture) async throws {
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

private func seedMangaOfflineCache(_ fixture: SystemSettingsFixture) async throws {
    let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/offline-seed.jpg"))
    try await fixture.offlineCacheStore.saveOfflineImageData(Data(repeating: 9, count: 2048), for: imageURL)
    try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
        try makeMangaOfflineMembership(ownerName: "favorite-seed", tid: "902", imageURLs: [imageURL])
    )
}

private func makeMangaOfflineMembership(
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

private func makeSystemSettingsOfflineSourcePage(tid: String) -> ForumThreadPage {
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

private func makeMangaOfflineWorkRequest(
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

private func cacheLabel(for bytes: Int) -> String {
    let megabytes = Double(max(0, bytes)) / 1_048_576
    return String(format: "%.2f MB", megabytes)
}

@MainActor
private func waitFor(
    timeout: TimeInterval = 2,
    pollInterval: UInt64 = 20_000_000,
    condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
    XCTFail("Timed out waiting for condition")
}

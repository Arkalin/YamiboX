import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

// The reading page's slice (board reader modes + novel offline cache) of the
// former SystemSettingsViewModelTests.
@MainActor
final class SettingsReadingViewModelTests: XCTestCase {
    func testLoadReadsNovelOfflineCacheSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        let savedSettings = NovelOfflineCacheSettings(
            retainsInlineImages: true,
            isAutoRefreshEnabled: false
        )
        try await fixture.settingsStore.save(AppSettings(novelOfflineCache: savedSettings))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.load()

        XCTAssertEqual(settings.reading.novelOfflineCache, savedSettings)
    }

    func testUpdateNovelOfflineCacheSettingsPersistsSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings())

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.reading
        await settings.load()
        XCTAssertFalse(viewModel.novelOfflineCache.retainsInlineImages)
        XCTAssertTrue(viewModel.novelOfflineCache.isAutoRefreshEnabled)

        viewModel.updateNovelOfflineCacheRetainsInlineImages(true)
        try await waitForSettings {
            await fixture.settingsStore.load().novelOfflineCache.retainsInlineImages
        }
        viewModel.updateNovelOfflineCacheAutoRefreshEnabled(false)

        try await waitForSettings {
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
        let fixture = try makeSystemSettingsFixture()
        var seeded = BoardReaderSettings()
        seeded.setEntry(.init(mode: .manga(smartEnabled: false)), forumID: "30")
        seeded.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
        try await fixture.settingsStore.save(AppSettings(boardReader: seeded))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.load()

        XCTAssertFalse(settings.reading.boardReader.isSmartComicModeEnabled(forumID: "30"))
        XCTAssertTrue(settings.reading.boardReader.isSmartComicModeEnabled(forumID: "46"))
        XCTAssertFalse(settings.reading.boardReader.isSmartComicModeEnabled(forumID: "37"))
    }

    /// The overview's smart-bit write side: flipping fid 30 off and fid 46
    /// on persists through `SettingsStore`, exercised independently for both
    /// directions (enabling and disabling) on two different
    /// manga-configured boards.
    func testSetBoardReaderModeFlipsSmartBitAndPersistsSettings() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings())

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.reading
        await settings.load()
        XCTAssertTrue(viewModel.boardReader.isSmartComicModeEnabled(forumID: "30"))
        XCTAssertFalse(viewModel.boardReader.isSmartComicModeEnabled(forumID: "46"))

        viewModel.setBoardReaderMode(.manga(smartEnabled: false), forumID: "30", boardName: "中文百合漫画区")
        viewModel.setBoardReaderMode(.manga(smartEnabled: true), forumID: "46", boardName: nil)

        try await waitForSettings {
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
        let fixture = try makeSystemSettingsFixture()
        var seeded = BoardReaderSettings()
        seeded.setEntry(.init(mode: .manga(smartEnabled: true), boardName: "中文百合漫画区"), forumID: "30")
        try await fixture.settingsStore.save(AppSettings(boardReader: seeded))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.reading
        await settings.load()
        viewModel.setBoardReaderMode(.novel, forumID: "30", boardName: "中文百合漫画区")

        try await waitForSettings {
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
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.save(AppSettings())

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.reading
        await settings.load()
        XCTAssertNotNil(viewModel.boardReader.entry(forumID: "49"))

        viewModel.setBoardReaderMode(.normal, forumID: "49", boardName: "小说板块")

        let expected = BoardReaderSettings.Entry(mode: .normal, boardName: "小说板块")
        try await waitForSettings {
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
        let fixture = try makeSystemSettingsFixture()
        var customized = BoardReaderSettings(entries: [:])
        customized.setEntry(.init(mode: .novel, boardName: "自定义板块"), forumID: "99")
        try await fixture.settingsStore.save(AppSettings(boardReader: customized))

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.reading
        await settings.load()
        XCTAssertEqual(viewModel.boardReader, customized)

        viewModel.resetBoardReader()

        try await waitForSettings {
            let loaded = await fixture.settingsStore.load()
            return loaded.boardReader == .factoryDefault
        }
        XCTAssertEqual(viewModel.boardReader, .factoryDefault)
    }
}

import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class SettingsPersistenceTests: XCTestCase {
    func testDelayedHomePageEditPreservesAConcurrentThemeEdit() async throws {
        let fixture = try makeSystemSettingsFixture()
        let updater = PausedSettingsUpdater(store: fixture.settingsStore)
        let viewModel = SettingsGeneralViewModel(
            dependencies: fixture.appContext.settingsDependencies,
            activity: SystemSettingsActivity(),
            updateSettings: { try await updater.update($0) }
        )
        viewModel.updateHomePage(.forum)
        try await waitForSettings { await updater.isWaiting }
        viewModel.updateThemePreset(.rose)
        try await waitForSettings { await fixture.settingsStore.load().appearance.themePreset == .rose }

        await updater.release()
        try await waitForSettings { await fixture.settingsStore.load().system.homePage == .forum }

        let saved = await fixture.settingsStore.load()
        XCTAssertEqual(saved.appearance.themePreset, .rose)
    }

    func testDelayedDisplayEditPreservesConcurrentTapPreferenceAndBothReaderSaves() async throws {
        let fixture = try makeSystemSettingsFixture()
        let updater = PausedSettingsUpdater(store: fixture.settingsStore)
        let viewModel = makeFavoritesViewModel(fixture, updater: updater)
        viewModel.updateFavoriteLayoutMode(.fixedGrid)
        try await waitForSettings { await updater.isWaiting }

        viewModel.updateFavoriteItemTapAction(.read)
        let novel = NovelReaderViewModel(
            context: NovelLaunchContext(threadID: "101", threadTitle: "Novel", source: .forum),
            dependencies: fixture.appContext.novelReaderDependencies
        )
        let manga = MangaReaderViewModel(
            context: MangaLaunchContext(
                originalThreadID: "102", chapterTID: "102", displayTitle: "Manga", source: .forum
            ),
            dependencies: fixture.appContext.mangaReaderDependencies
        )
        let novelSettings = NovelReaderAppearanceSettings(fontScale: 1.2)
        let mangaSettings = MangaReaderSettings(brightness: 0.6)
        await novel.commitNovelTextAppearance(novelSettings)
        manga.applySettings(mangaSettings)
        try await waitForSettings {
            let saved = await fixture.settingsStore.load()
            return saved.favorites.itemTapAction == .read
                && saved.novelReader == novelSettings
                && saved.manga == mangaSettings
        }

        await updater.release()
        try await waitForSettings { await fixture.settingsStore.load().favorites.layoutMode == .fixedGrid }
        let saved = await fixture.settingsStore.load()
        XCTAssertEqual(saved.favorites.itemTapAction, .read)
        XCTAssertEqual(saved.novelReader, novelSettings)
        XCTAssertEqual(saved.manga, mangaSettings)
    }

    func testDisplayEditMutatesOnlyTheEditedFieldWhenAnotherSurfaceChangesSortOrder() async throws {
        let fixture = try makeSystemSettingsFixture()
        let updater = PausedSettingsUpdater(store: fixture.settingsStore)
        let viewModel = makeFavoritesViewModel(fixture, updater: updater)
        viewModel.updateFavoriteLayoutMode(.fixedGrid)
        try await waitForSettings { await updater.isWaiting }
        try await fixture.settingsStore.update { $0.favorites.sortOrder = .lastReadAt }

        await updater.release()
        try await waitForSettings { await fixture.settingsStore.load().favorites.layoutMode == .fixedGrid }

        let saved = await fixture.settingsStore.load()
        XCTAssertEqual(saved.favorites.sortOrder, .lastReadAt)
    }

    func testFailedOlderEditCannotRollbackANewerEditWithTheSameValue() async throws {
        let fixture = try makeSystemSettingsFixture()
        let updater = PausedSettingsUpdater(store: fixture.settingsStore, failsFirstEdit: true)
        let viewModel = makeFavoritesViewModel(fixture, updater: updater)
        viewModel.updateFavoriteLayoutMode(.fixedGrid)
        try await waitForSettings { await updater.isWaiting }
        viewModel.updateFavoriteLayoutMode(.staggered)
        try await waitForSettings { await fixture.settingsStore.load().favorites.layoutMode == .staggered }
        viewModel.updateFavoriteLayoutMode(.fixedGrid)
        try await waitForSettings { await fixture.settingsStore.load().favorites.layoutMode == .fixedGrid }

        await updater.release()
        try await waitForSettings { viewModel.errorMessage != nil }

        XCTAssertEqual(viewModel.favoriteLayoutMode, .fixedGrid)
        let saved = await fixture.settingsStore.load()
        XCTAssertEqual(saved.favorites.layoutMode, .fixedGrid)
    }

    func testTwoFailedEditsRestorePersistedValueWhenOlderEditFailsFirst() async throws {
        try await assertTwoFailedEditsRestorePersistedValue(finishingOrder: [1, 2])
    }

    func testTwoFailedEditsRestorePersistedValueWhenNewerEditFailsFirst() async throws {
        try await assertTwoFailedEditsRestorePersistedValue(finishingOrder: [2, 1])
    }

    func testNewerFailureRollsBackToEarlierSuccessfulEdit() async throws {
        let fixture = try makeSystemSettingsFixture()
        let updater = ControlledSettingsUpdater(store: fixture.settingsStore)
        let viewModel = SettingsFavoritesViewModel(
            dependencies: fixture.appContext.settingsDependencies,
            activity: SystemSettingsActivity(),
            updateSettings: { try await updater.update($0) }
        )
        viewModel.updateFavoriteLayoutMode(.fixedGrid)
        try await waitForSettings { await updater.waitingCount == 1 }
        viewModel.updateFavoriteLayoutMode(.staggered)
        try await waitForSettings { await updater.waitingCount == 2 }

        await updater.succeed(1)
        try await waitForSettings { await fixture.settingsStore.load().favorites.layoutMode == .fixedGrid }
        await updater.fail(2)
        try await waitForSettings { viewModel.errorMessage == "Settings edit 2 failed" }

        XCTAssertEqual(viewModel.favoriteLayoutMode, .fixedGrid)
        let saved = await fixture.settingsStore.load()
        XCTAssertEqual(saved.favorites.layoutMode, .fixedGrid)
    }

    func testPeripheralAndOfflineCacheTogglesPreserveSiblingFieldsChangedElsewhere() async throws {
        let fixture = try makeSystemSettingsFixture()
        let activity = SystemSettingsActivity()
        let peripherals = SettingsPeripheralsViewModel(
            dependencies: fixture.appContext.settingsDependencies, activity: activity
        )
        let reading = SettingsReadingViewModel(
            dependencies: fixture.appContext.settingsDependencies, activity: activity
        )
        try await fixture.settingsStore.update {
            $0.system.applePencilPageTurn.behavior = .doubleTapNextSqueezePrevious
            $0.system.gamepad.bind(.nextPage, toElementAlias: GamepadElementAlias.buttonY)
            $0.system.keyboard.bind(.previousPage, toKeyCode: 7)
            $0.novelOfflineCache.retainsInlineImages = true
        }

        peripherals.updateApplePencilPageTurnEnabled(true)
        peripherals.updateGamepadEnabled(false)
        peripherals.updateKeyboardEnabled(false)
        reading.updateNovelOfflineCacheAutoRefreshEnabled(false)
        try await waitForSettings {
            let saved = await fixture.settingsStore.load()
            return saved.system.applePencilPageTurn.isEnabled
                && !saved.system.gamepad.isEnabled && !saved.system.keyboard.isEnabled
                && !saved.novelOfflineCache.isAutoRefreshEnabled
        }

        let saved = await fixture.settingsStore.load()
        XCTAssertEqual(saved.system.applePencilPageTurn.behavior, .doubleTapNextSqueezePrevious)
        XCTAssertEqual(saved.system.gamepad.bindings[.nextPage], GamepadElementAlias.buttonY)
        XCTAssertEqual(saved.system.keyboard.bindings[.previousPage], 7)
        XCTAssertTrue(saved.novelOfflineCache.retainsInlineImages)
    }

    private func makeFavoritesViewModel(
        _ fixture: SystemSettingsFixture,
        updater: PausedSettingsUpdater
    ) -> SettingsFavoritesViewModel {
        SettingsFavoritesViewModel(
            dependencies: fixture.appContext.settingsDependencies,
            activity: SystemSettingsActivity(),
            updateSettings: { try await updater.update($0) }
        )
    }

    private func assertTwoFailedEditsRestorePersistedValue(finishingOrder: [Int]) async throws {
        let fixture = try makeSystemSettingsFixture()
        try await fixture.settingsStore.update {
            $0.appearance.themePreset = .rose
            $0.system.homePage = .forum
        }
        let updater = ControlledSettingsUpdater(store: fixture.settingsStore)
        let viewModel = SettingsFavoritesViewModel(
            dependencies: fixture.appContext.settingsDependencies,
            activity: SystemSettingsActivity(),
            updateSettings: { try await updater.update($0) }
        )
        let original = await fixture.settingsStore.load()
        viewModel.applyLoadedSettings(original)
        viewModel.updateFavoriteLayoutMode(.fixedGrid)
        try await waitForSettings { await updater.waitingCount == 1 }
        viewModel.updateFavoriteLayoutMode(.staggered)
        try await waitForSettings { await updater.waitingCount == 2 }

        await updater.fail(finishingOrder[0])
        try await waitForSettings { viewModel.errorMessage == "Settings edit \(finishingOrder[0]) failed" }
        XCTAssertEqual(viewModel.favoriteLayoutMode, finishingOrder[0] == 1 ? .staggered : .fixedGrid)
        let afterFirstFailure = await fixture.settingsStore.load()
        XCTAssertEqual(afterFirstFailure, original)
        await updater.fail(finishingOrder[1])
        try await waitForSettings { viewModel.errorMessage == "Settings edit \(finishingOrder[1]) failed" }

        XCTAssertEqual(viewModel.favoriteLayoutMode, original.favorites.layoutMode)
        let saved = await fixture.settingsStore.load()
        XCTAssertEqual(saved, original)
    }
}

private actor PausedSettingsUpdater {
    let store: SettingsStore
    let failsFirstEdit: Bool
    private var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    init(store: SettingsStore, failsFirstEdit: Bool = false) {
        self.store = store
        self.failsFirstEdit = failsFirstEdit
    }

    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws -> AppSettings {
        callCount += 1
        if callCount == 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
            if failsFirstEdit { throw YamiboError.underlying("Settings save failed") }
        }
        return try await store.update(mutate)
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}

private actor ControlledSettingsUpdater {
    private let store: SettingsStore
    private var nextCall = 0
    private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]

    var waitingCount: Int { continuations.count }

    init(store: SettingsStore) {
        self.store = store
    }

    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws -> AppSettings {
        nextCall += 1
        let call = nextCall
        try await withCheckedThrowingContinuation { continuation in
            continuations[call] = continuation
        }
        return try await store.update(mutate)
    }

    func fail(_ call: Int) {
        continuations.removeValue(forKey: call)?.resume(throwing: YamiboError.underlying("Settings edit \(call) failed"))
    }

    func succeed(_ call: Int) {
        continuations.removeValue(forKey: call)?.resume()
    }
}

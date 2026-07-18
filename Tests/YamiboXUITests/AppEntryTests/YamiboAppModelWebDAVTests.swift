import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

final class YamiboAppModelWebDAVTests: XCTestCase {
    @MainActor
    func testReadingProgressChangeSchedulesWebDAVLocalUpdate() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "app-model-reading-progress-webdav")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let webDAVSettingsStore = WebDAVSyncSettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "webdav"
        )
        try await webDAVSettingsStore.save(WebDAVSyncSettings(isAutoSyncEnabled: true))
        let appContext = YamiboAppContext(webDAVSyncSettingsStore: webDAVSettingsStore)
        let appModel = YamiboAppModel(appContext: appContext)

        appModel.scheduleWebDAVUploadForReadingProgressChange()

        // markLocalDataChanged now runs after the 2s debounce sleep (not before
        // it), so this needs a longer poll window than the pre-fix 1s default.
        let localUpdatedAt = try await Self.waitForLocalUpdatedAt(in: webDAVSettingsStore, timeout: 3.5)
        XCTAssertNotNil(localUpdatedAt)
        // Every fingerprint-tracked participant gets fingerprinted unconditionally
        // now (not just when touchesAppSettings is set), and this is the first
        // call ever, so all of them lack a prior baseline and come up dirty.
        let dirtyDatasetIDs = await webDAVSettingsStore.load().dirtyDatasetIDs
        XCTAssertFalse(dirtyDatasetIDs.isEmpty)
    }

    @MainActor
    func testReadingProgressStoreNotificationSchedulesWebDAVLocalUpdate() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "app-model-reading-progress-notification")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let webDAVSettingsStore = WebDAVSyncSettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "webdav"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        try await webDAVSettingsStore.save(WebDAVSyncSettings(isAutoSyncEnabled: true))
        let appContext = YamiboAppContext(
            webDAVSyncSettingsStore: webDAVSettingsStore,
            readingProgressStore: readingProgressStore
        )
        let appModel = YamiboAppModel(appContext: appContext)
        let observerTask = Task {
            await RootTabView.observeReadingProgressChanges(appContext: appContext) {
                appModel.scheduleWebDAVUploadForReadingProgressChange()
            }
        }
        defer { observerTask.cancel() }
        try await Task.sleep(nanoseconds: 50_000_000)

        try await readingProgressStore.saveNovel(NovelReadingPosition(threadID: "2701", view: 2))

        // markLocalDataChanged now runs after the 2s debounce sleep (not before
        // it), so this needs a longer poll window than the pre-fix 1s default.
        let localUpdatedAt = try await Self.waitForLocalUpdatedAt(in: webDAVSettingsStore, timeout: 3.5)
        XCTAssertNotNil(localUpdatedAt)
        // Every fingerprint-tracked participant gets fingerprinted unconditionally
        // now (not just when touchesAppSettings is set), and this is the first
        // call ever, so all of them lack a prior baseline and come up dirty.
        let dirtyDatasetIDs = await webDAVSettingsStore.load().dirtyDatasetIDs
        XCTAssertFalse(dirtyDatasetIDs.isEmpty)
    }

    private static func waitForLocalUpdatedAt(
        in store: WebDAVSyncSettingsStore,
        timeout: TimeInterval = 1
    ) async throws -> Date? {
        do {
            try await waitForCondition(timeout: .seconds(timeout), pollInterval: .milliseconds(20)) {
                await store.load().localUpdatedAt != nil
            }
        } catch is TestWaitTimeoutError {
            // 与原实现一致:超时后返回最终读到的值(可能为 nil),由调用方断言。
        }
        return await store.load().localUpdatedAt
    }
}

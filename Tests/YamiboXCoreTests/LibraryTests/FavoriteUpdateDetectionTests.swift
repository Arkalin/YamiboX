import Foundation
import Testing
@testable import YamiboXCore

@Suite("LibraryTests: Favorite Update Detection")
struct FavoriteUpdateDetectionTests {
    // MARK: - FavoriteUpdateTargetKey identifiers

    // Tap-routing (in-app updates page, and the notification's userInfo,
    // which only carries the id string) both re-derive `cleanBookName` from
    // this id via `mangaDirectoryCleanBookName(fromID:)` — it must be a true
    // inverse of `.mangaDirectory(cleanBookName:).id`, including for a
    // cleanBookName that itself contains a colon.
    @Test func mangaDirectoryIDRoundTripsThroughCleanBookNameParsing() {
        let key = FavoriteUpdateTargetKey.mangaDirectory(cleanBookName: "测试:漫画")
        #expect(FavoriteUpdateTargetKey.mangaDirectoryCleanBookName(fromID: key.id) == "测试:漫画")
    }

    @Test func favoriteTargetIDIsNeverMistakenForAMangaDirectoryID() {
        let key = FavoriteUpdateTargetKey.favorite(FavoriteItemTarget(kind: .normalThread, threadID: "123"))
        #expect(FavoriteUpdateTargetKey.mangaDirectoryCleanBookName(fromID: key.id) == nil)
    }

    // MARK: - SmartMangaUpdateCheckInterval

    @Test func smartMangaIntervalHasNoSubDayTier() {
        // By construction, not merely by convention: there is no case here
        // that could ever be misused as a fast/flood-risking tier.
        #expect(SmartMangaUpdateCheckInterval.allCases == [.off, .day, .threeDays, .week, .smart])
    }

    @Test func smartMangaIntervalOffNeverReportsDue() {
        #expect(SmartMangaUpdateCheckInterval.off.nextDelay(hasRecentEvents: false) == nil)
        #expect(SmartMangaUpdateCheckInterval.off.nextDelay(hasRecentEvents: true) == nil)
    }

    @Test func smartMangaIntervalFixedTiersIgnoreRecentEvents() {
        let oneDay: TimeInterval = 24 * 3600
        let threeDays: TimeInterval = 3 * 24 * 3600
        let oneWeek: TimeInterval = 7 * 24 * 3600
        #expect(SmartMangaUpdateCheckInterval.day.nextDelay(hasRecentEvents: false) == oneDay)
        #expect(SmartMangaUpdateCheckInterval.day.nextDelay(hasRecentEvents: true) == oneDay)
        #expect(SmartMangaUpdateCheckInterval.threeDays.nextDelay(hasRecentEvents: false) == threeDays)
        #expect(SmartMangaUpdateCheckInterval.week.nextDelay(hasRecentEvents: false) == oneWeek)
    }

    @Test func smartMangaIntervalSmartTierAdaptsButNeverGoesSubDay() throws {
        let oneDay: TimeInterval = 24 * 3600
        let threeDays: TimeInterval = 3 * 24 * 3600
        let active = SmartMangaUpdateCheckInterval.smart.nextDelay(hasRecentEvents: true)
        let quiet = SmartMangaUpdateCheckInterval.smart.nextDelay(hasRecentEvents: false)
        #expect(active == oneDay)
        #expect(quiet == threeDays)
        #expect(try #require(active) >= oneDay)
    }

    // MARK: - FavoriteUpdateStore.renameMangaDirectoryTracking

    private func makeStore(function: String = #function) -> FavoriteUpdateStore {
        let suiteName = "favorite-update-detection-\(function)-\(UUID().uuidString)"
        return FavoriteUpdateStore(defaults: UserDefaults(suiteName: suiteName)!, key: "favorite-updates")
    }

    @Test func renameMangaDirectoryTrackingMovesTrackedTargetAndEventWhenDestinationIsFree() async throws {
        let store = makeStore()
        try await store.upsertTrackedTarget(FavoriteUpdateTrackedTarget(
            target: .mangaDirectory(cleanBookName: "旧名"),
            title: "旧名",
            mode: .mangaDirectory,
            knownChapterTIDs: ["1", "2"],
            baselineReady: true
        ))
        try await store.insertEvent(FavoriteUpdateEvent(
            target: .mangaDirectory(cleanBookName: "旧名"),
            title: "旧名",
            mode: .mangaDirectory,
            summary: .newChapters(count: 1),
            detailIDs: ["2"]
        ))

        try await store.renameMangaDirectoryTracking(from: "旧名", to: "新名")

        let state = await store.loadState()
        #expect(state.trackedTargets.map(\.target) == [.mangaDirectory(cleanBookName: "新名")])
        #expect(state.trackedTargets.first?.knownChapterTIDs == ["1", "2"])
        #expect(state.events.map(\.target) == [.mangaDirectory(cleanBookName: "新名")])
        #expect(state.events.first?.title == "新名")
    }

    @Test func renameMangaDirectoryTrackingMergesIntoAlreadyTrackedDestination() async throws {
        let store = makeStore()
        try await store.upsertTrackedTarget(FavoriteUpdateTrackedTarget(
            target: .mangaDirectory(cleanBookName: "旧名"),
            title: "旧名",
            mode: .mangaDirectory,
            knownChapterTIDs: ["1"],
            baselineReady: true
        ))
        try await store.upsertTrackedTarget(FavoriteUpdateTrackedTarget(
            target: .mangaDirectory(cleanBookName: "新名"),
            title: "新名",
            mode: .mangaDirectory,
            knownChapterTIDs: ["9"],
            baselineReady: true
        ))
        let older = FavoriteUpdateEvent(
            target: .mangaDirectory(cleanBookName: "旧名"),
            title: "旧名",
            mode: .mangaDirectory,
            summary: .newChapters(count: 1),
            detectedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = FavoriteUpdateEvent(
            target: .mangaDirectory(cleanBookName: "新名"),
            title: "新名",
            mode: .mangaDirectory,
            summary: .newChapters(count: 1),
            detectedAt: Date(timeIntervalSince1970: 2_000)
        )
        try await store.insertEvent(older)
        try await store.insertEvent(newer)

        try await store.renameMangaDirectoryTracking(from: "旧名", to: "新名")

        let state = await store.loadState()
        // Merge target: baseline is the UNION of both sides, never a
        // shrink — the same monotonic-growth invariant the check loop itself
        // relies on.
        #expect(state.trackedTargets.count == 1)
        #expect(state.trackedTargets.first?.knownChapterTIDs == ["1", "9"])
        // Merge events: the two now-colliding undismissed events for the
        // same merged target collapse to just the more recently detected one.
        #expect(state.events.count == 1)
        #expect(state.events.first?.id == newer.id)
    }

    @Test func renameMangaDirectoryTrackingIsNoOpWhenNamesAreEqualOrNothingTracked() async throws {
        let store = makeStore()
        try await store.renameMangaDirectoryTracking(from: "同名", to: "同名")
        try await store.renameMangaDirectoryTracking(from: "不存在", to: "也不存在")
        let state = await store.loadState()
        #expect(state.trackedTargets.isEmpty)
        #expect(state.events.isEmpty)
    }
}

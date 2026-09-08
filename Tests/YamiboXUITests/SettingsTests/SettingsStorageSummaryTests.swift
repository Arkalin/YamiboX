import XCTest
import YamiboXCore
@testable import YamiboXUI

@MainActor
final class SettingsStorageSummaryTests: XCTestCase {
    func testDistributionUsesActualProportions() {
        let summary = SettingsStorageSummary(categories: [
            .init(category: .images, bytes: 750),
            .init(category: .offline, bytes: 250),
            .init(category: .history, bytes: 0)
        ], hasLoaded: true)

        XCTAssertEqual(summary.totalBytes, 1000)
        XCTAssertEqual(summary.fraction(for: summary.categories[0]), 0.75)
        XCTAssertEqual(summary.fraction(for: summary.categories[1]), 0.25)
        XCTAssertEqual(summary.fraction(for: summary.categories[2]), 0)
        XCTAssertEqual(summary.categories.reduce(0) { $0 + summary.fraction(for: $1) }, 1)
        XCTAssertEqual(summary.totalLabel, L10n.string("settings.storage_usage_total_value", SettingsStorageUsage.cacheLabel(for: 1000)))
    }

    func testEmptyDataHasZeroTotalAndNoInvalidFractions() {
        let summary = SettingsStorageSummary(categories: [
            .init(category: .images, bytes: 0),
            .init(category: .history, bytes: 0)
        ], hasLoaded: true)

        XCTAssertEqual(summary.totalBytes, 0)
        XCTAssertEqual(summary.totalLabel, SettingsStorageUsage.cacheLabel(for: 0))
        for usage in summary.categories {
            XCTAssertEqual(summary.fraction(for: usage), 0)
        }
    }

    func testMissingCategoryDoesNotProduceMisleadingTotal() {
        let categories: [SettingsStorageCategoryUsage] = [
            .init(category: .images, bytes: 1000),
            .init(category: .history, bytes: nil)
        ]
        let loading = SettingsStorageSummary(categories: categories, hasLoaded: false)
        let failed = SettingsStorageSummary(categories: categories, hasLoaded: true)
        XCTAssertNil(loading.totalBytes)
        XCTAssertNil(failed.totalBytes)
        XCTAssertEqual(loading.totalLabel, L10n.string("settings.storage_usage_calculating"))
        XCTAssertEqual(failed.totalLabel, L10n.string("settings.storage_usage_unavailable"))
        XCTAssertEqual(failed.fraction(for: categories[0]), 0)
    }

    func testSummaryIncludesEveryCategoryAndRefreshesAfterClear() async throws {
        let fixture = try makeSystemSettingsFixture()
        fixture.ordinaryImageCache.diskUsageBytes = 1000
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        await settings.storage.refreshStorageUsage()
        let before = settings.storage.summary
        XCTAssertEqual(before.categories.map(\.category), SettingsStorageCategory.allCases)
        XCTAssertEqual(before.categories.first { $0.category == .images }?.bytes, 1000)
        let beforeTotal = try XCTUnwrap(before.totalBytes)
        XCTAssertGreaterThanOrEqual(beforeTotal, 1000)

        let didClear = await settings.storage.clearImageCache()
        XCTAssertTrue(didClear)
        let after = settings.storage.summary
        XCTAssertEqual(after.categories.first { $0.category == .images }?.bytes, 0)
        XCTAssertEqual(after.totalBytes, beforeTotal - 1000)
    }
}

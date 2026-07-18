import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

// The offline cache management page's slice of the former
// SystemSettingsViewModelTests.
@MainActor
final class OfflineCacheManagementViewModelTests: XCTestCase {
    func testOfflineCacheManagementFiltersOwnersWithMembershipOrWorkAndShowsUsage() async throws {
        let fixture = try makeSystemSettingsFixture()
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

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
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
        let fixture = try makeSystemSettingsFixture()
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement

        await viewModel.refreshOfflineCacheManagement()

        XCTAssertTrue(viewModel.offlineCacheManagementRows.isEmpty)
        XCTAssertTrue(viewModel.offlineCacheManagementIsEmpty)
    }

    func testOfflineCacheManagementSingleAndSwipeDeletePrepareConfirmation() async throws {
        let fixture = try makeSystemSettingsFixture()
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/offline-single.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [imageURL])
        )
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
        await viewModel.refreshOfflineCacheManagement()

        viewModel.requestOfflineCacheGroupDeletion(id: mangaOfflineGroupID("作品A"))
        XCTAssertEqual(viewModel.pendingOfflineCacheManagementConfirmation?.groupIDs.map(\.ownerKey), ["作品A"])

        viewModel.cancelOfflineCacheManagementConfirmation()
        viewModel.requestOfflineCacheSwipeGroupDeletion(id: mangaOfflineGroupID("作品A"))
        XCTAssertEqual(viewModel.pendingOfflineCacheManagementConfirmation?.groupIDs.map(\.ownerKey), ["作品A"])
    }

    func testOfflineCacheManagementBatchDeleteUsesOneConfirmationForSelectedOwners() async throws {
        let fixture = try makeSystemSettingsFixture()
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
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
        await viewModel.refreshOfflineCacheManagement()

        viewModel.setOfflineCacheManagementSelectionMode(true)
        viewModel.toggleOfflineCacheManagementSelection(id: mangaOfflineGroupID("作品A"))
        viewModel.toggleOfflineCacheManagementSelection(id: mangaOfflineGroupID("作品B"))
        viewModel.requestSelectedOfflineCacheGroupDeletion()

        XCTAssertEqual(viewModel.pendingOfflineCacheManagementConfirmation?.groupIDs.map(\.ownerKey), ["作品A", "作品B"])
    }

    func testOfflineCacheManagementSelectionActionStateEnablesDeleteWhenOwnerIsSelected() async throws {
        let fixture = try makeSystemSettingsFixture()
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/offline-selection-state.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [imageURL])
        )
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
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
        let fixture = try makeSystemSettingsFixture()
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
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
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
        let fixture = try makeSystemSettingsFixture()
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
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
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
        let fixture = try makeSystemSettingsFixture()
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
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
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
        let fixture = try makeSystemSettingsFixture()
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/dismiss-race.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [imageURL])
        )
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
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
        let fixture = try makeSystemSettingsFixture()
        try await seedMangaIndexCache(fixture)
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/901-1.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "901", imageURLs: [imageURL])
        )
        let directoryBytesBeforeClear = await fixture.mangaDirectoryStore.totalDiskUsageBytes()
        let projectionBytesBeforeClear = await fixture.mangaReaderProjectionStore.totalDiskUsageBytes()
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.offlineCacheManagement
        await viewModel.refreshOfflineCacheManagement()

        viewModel.requestOfflineCacheGroupDeletion(id: mangaOfflineGroupID("作品A"))
        let didDelete = await viewModel.confirmPendingOfflineCacheManagementDeletion()

        let directoryBytesAfterClear = await fixture.mangaDirectoryStore.totalDiskUsageBytes()
        let projectionBytesAfterClear = await fixture.mangaReaderProjectionStore.totalDiskUsageBytes()

        XCTAssertTrue(didDelete)
        XCTAssertEqual(directoryBytesAfterClear, directoryBytesBeforeClear)
        XCTAssertEqual(projectionBytesAfterClear, projectionBytesBeforeClear)
    }
}

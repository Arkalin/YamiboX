import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

// The manga directory management page's slice of the former
// SystemSettingsViewModelTests.
@MainActor
final class MangaDirectoryManagementViewModelTests: XCTestCase {
    func testMangaDirectoryManagementListsDirectoriesWithChapterCounts() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101", "102"])
        try await seedMangaDirectory(fixture, cleanBookName: "作品B", chapterTIDs: ["201"])

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.mangaDirectoryManagement
        await viewModel.refreshMangaDirectoryManagement()

        let rowsByTitle = Dictionary(uniqueKeysWithValues: viewModel.mangaDirectoryManagementRows.map { ($0.title, $0) })
        XCTAssertEqual(rowsByTitle["作品A"]?.chapterCount, 2)
        XCTAssertEqual(rowsByTitle["作品B"]?.chapterCount, 1)
        XCTAssertFalse(viewModel.mangaDirectoryManagementIsEmpty)
    }

    func testMangaDirectoryManagementSingleDeletePreparesConfirmation() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101"])
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.mangaDirectoryManagement
        await viewModel.refreshMangaDirectoryManagement()

        viewModel.requestMangaDirectoryDeletion(id: "作品A")
        XCTAssertEqual(viewModel.pendingMangaDirectoryManagementConfirmation?.directoryIDs, ["作品A"])

        viewModel.cancelMangaDirectoryManagementConfirmation()
        XCTAssertNil(viewModel.pendingMangaDirectoryManagementConfirmation)
    }

    func testMangaDirectoryManagementBatchDeleteUsesOneConfirmationForSelectedDirectories() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101"])
        try await seedMangaDirectory(fixture, cleanBookName: "作品B", chapterTIDs: ["201"])
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.mangaDirectoryManagement
        await viewModel.refreshMangaDirectoryManagement()

        viewModel.setMangaDirectoryManagementSelectionMode(true)
        viewModel.toggleMangaDirectoryManagementSelection(id: "作品A")
        viewModel.toggleMangaDirectoryManagementSelection(id: "作品B")
        viewModel.requestSelectedMangaDirectoryDeletion()

        XCTAssertEqual(viewModel.pendingMangaDirectoryManagementConfirmation?.directoryIDs, ["作品A", "作品B"])
    }

    func testMangaDirectoryManagementConfirmDeletesOnlySelectedDirectories() async throws {
        let fixture = try makeSystemSettingsFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101"])
        try await seedMangaDirectory(fixture, cleanBookName: "作品B", chapterTIDs: ["201"])
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.mangaDirectoryManagement
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
        let fixture = try makeSystemSettingsFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["310"])
        let imageURL = try XCTUnwrap(URL(string: "https://img.example.com/directory-delete-310.jpg"))
        try await fixture.offlineCacheStore.saveOfflineImageData(Data([1]), for: imageURL)
        try await fixture.offlineCacheStore.saveMangaOfflineCacheMembership(
            try makeMangaOfflineMembership(ownerName: "作品A", tid: "310", imageURLs: [imageURL])
        )
        try await fixture.appContext.favoriteUpdateStore.upsertTrackedTarget(
            makeMangaDirectoryTrackedTarget(cleanBookName: "作品A")
        )

        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.mangaDirectoryManagement
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
        let fixture = try makeSystemSettingsFixture()
        try await seedMangaDirectory(fixture, cleanBookName: "作品A", chapterTIDs: ["101"])
        try await seedMangaDirectory(fixture, cleanBookName: "作品B", chapterTIDs: ["201"])
        let settings = SystemSettingsViewModel(dependencies: fixture.appContext.settingsDependencies)
        let viewModel = settings.mangaDirectoryManagement
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

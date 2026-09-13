import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class BrowsingHistoryCategoryNavigationTests: XCTestCase {
    func testAllHasConcreteSelectionAndSidebarTracksPhonePickerAndReset() throws {
        let context = try makeContext()
        let model = BrowsingHistoryViewModel(dependencies: context.libraryDependencies)
        XCTAssertEqual(model.availableFilters, [.all, .normal, .novel, .manga])
        XCTAssertEqual(model.selectedFilter, .all)
        XCTAssertNil(model.selectedCategory)

        for filter in BrowsingHistoryFilter.allCases {
            model.selectedFilter = filter
            XCTAssertEqual(model.selectedCategory, filter.category)
            XCTAssertEqual(model.selectedFilter, filter)
            XCTAssertEqual(filter.title, L10n.string("history.filter.\(filter.rawValue)"))
        }

        model.selectedCategory = .novel
        XCTAssertEqual(model.selectedFilter, .novel)
        model.selectedCategory = nil
        XCTAssertEqual(model.selectedFilter, .all)
    }

    func testSidebarSelectionPreservesSearchAndFiltersUsingCurrentBoardCategory() async throws {
        let context = try makeContext()
        try await context.settingsStore.update {
            $0.boardReader.setEntry(.init(mode: .novel), forumID: "40")
        }
        let novel = BrowsingHistoryEntry(target: .normalThread(threadID: "1"), title: "Matching novel", forumID: "40")
        let canonicalNovelID = FavoriteContentTarget.novelThread(threadID: "1").id
        let manga = BrowsingHistoryEntry(target: .mangaThread(threadID: "2"), title: "Matching manga")
        let other = BrowsingHistoryEntry(target: .novelThread(threadID: "3"), title: "Other novel")
        for entry in [novel, manga, other] {
            try await context.browsingHistoryStore.record(entry)
        }
        let model = BrowsingHistoryViewModel(dependencies: context.libraryDependencies)
        model.searchText = "Matching"
        model.selectedFilter = .novel
        await model.load()
        XCTAssertEqual(model.entries.map(\.id), [canonicalNovelID])
        model.selectedFilter = .manga
        await model.reload()
        XCTAssertEqual(model.entries.map(\.id), [manga.id])
        model.selectedFilter = .all
        await model.reload()
        XCTAssertEqual(Set(model.entries.map(\.id)), Set([canonicalNovelID, manga.id]))
        XCTAssertEqual(model.searchText, "Matching")
    }

    func testPreviousReadingExcludesNormalCategoryAndRejectsInvalidSelection() throws {
        let context = try makeContext()
        let model = BrowsingHistoryViewModel(dependencies: context.libraryDependencies, showsPreviousReading: true)
        XCTAssertEqual(model.availableFilters, [.all, .novel, .manga])
        model.selectedFilter = .manga
        model.selectedFilter = .normal
        XCTAssertEqual(model.selectedFilter, .manga)
        XCTAssertEqual(model.selectedCategory, .manga)
        model.selectedFilter = .all
        XCTAssertNil(model.selectedCategory)
    }

    func testCancelledInitialLoadDoesNotPresentAnErrorAndCanLoadAgain() async throws {
        let context = try makeContext()
        XCTAssertNotNil(context.libraryDependencies.browsingHistoryWorkflow)
        let entry = BrowsingHistoryEntry(target: .normalThread(threadID: "1"), title: "History", forumID: "1")
        try await context.browsingHistoryStore.record(entry)
        let model = BrowsingHistoryViewModel(dependencies: context.libraryDependencies)

        let cancelledLoad = Task {
            // The real workflow checks cancellation before reading its snapshot.
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load()
        }
        await cancelledLoad.value

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.errorDetails)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.entries.isEmpty)

        await model.load()
        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.errorDetails)
    }

    func testCancelledReloadPreservesVisibleEntriesWithoutPresentingAnError() async throws {
        let context = try makeContext()
        let entry = BrowsingHistoryEntry(target: .normalThread(threadID: "2"), title: "Visible history", forumID: "1")
        try await context.browsingHistoryStore.record(entry)
        let model = BrowsingHistoryViewModel(dependencies: context.libraryDependencies)
        await model.load()
        XCTAssertEqual(model.entries.map(\.id), [entry.id])

        let cancelledReload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.reload()
        }
        await cancelledReload.value

        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.errorDetails)
        XCTAssertFalse(model.isLoading)
    }

    private func makeContext() throws -> YamiboAppContext {
        let name = "history-category-navigation-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        return YamiboAppContext(
            sessionStore: SessionStore(defaults: defaults, key: "session"),
            profileStore: YamiboProfileStore(defaults: defaults, key: "profile"),
            settingsStore: SettingsStore(defaults: defaults, key: "settings"),
            databasePool: try YamiboDatabase.openPool(rootDirectory: root.appendingPathComponent("database")),
            grdbRootDirectory: root,
            cachesRootDirectory: root.appendingPathComponent("caches"),
            uiDefaults: defaults,
            clearsWebDataOnReset: false
        )
    }
}

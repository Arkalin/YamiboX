import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class LocalFavoritesNavigationTests: XCTestCase {
    func testDetailAndNestedForumPopsPreserveCollectionAndFilter() async throws {
        let navigation = try await makeNavigation()
        let organizer = navigation.organizer
        let created = await organizer.createCollection(name: "Collection")
        let collection = try XCTUnwrap(created)
        organizer.openCollection(id: collection.id)
        organizer.filter.searchText = "Work"
        let detail = ContentDetailDestination.novel(.init(thread: .init(tid: "501"), title: "Work"))
        navigation.routes.detail = detail
        XCTAssertTrue(navigation.navigator.path.isEmpty)
        navigation.navigator.openUserSpace(uid: "42", name: "Author")

        XCTAssertEqual(navigation.path.count, 3)
        XCTAssertEqual(navigation.path.first, .collection(collection.id))
        navigation.path = Array(navigation.path.dropLast())
        XCTAssertEqual(navigation.path, [.collection(collection.id), .detail(detail)])
        navigation.path = Array(navigation.path.dropLast())
        XCTAssertEqual(navigation.path, [.collection(collection.id)])
        XCTAssertEqual(organizer.selectedCollectionID, collection.id)
        XCTAssertEqual(organizer.filter.searchText, "Work")
        XCTAssertTrue(navigation.navigator.path.isEmpty)
        XCTAssertNil(navigation.routes.detail)
        navigation.path = []
        XCTAssertNil(organizer.selectedCollectionID)
    }

    func testArchivePopReturnsToItsCollection() async throws {
        let navigation = try await makeNavigation()
        let created = await navigation.organizer.createCollection(name: "Collection")
        let collection = try XCTUnwrap(created)
        navigation.organizer.openCollection(id: collection.id)
        navigation.organizer.openMergedGroup(cleanBookName: "Work")
        XCTAssertEqual(navigation.path, [.collection(collection.id), .mergedGroup("Work")])
        navigation.path = [.collection(collection.id)]
        XCTAssertNil(navigation.organizer.selectedMergedGroupCleanBookName)
        XCTAssertEqual(navigation.organizer.selectedCollectionID, collection.id)
    }

    func testForumHomeLinkStaysAboveTheFavoriteDetail() async throws {
        let navigation = try await makeNavigation()
        let detail = ContentDetailDestination.novel(.init(thread: .init(tid: "501"), title: "Work"))
        navigation.routes.detail = detail
        let homeURL = try XCTUnwrap(URL(string: "https://bbs.yamibo.com/forum.php"))

        navigation.navigator.route(homeURL, source: .external)

        XCTAssertEqual(navigation.path, [.detail(detail), .forum(.home)])
        navigation.path = Array(navigation.path.dropLast())
        XCTAssertEqual(navigation.routes.detail, detail)
    }

    func testExistingAuxiliaryPagesStillPopWithoutChangingBrowseState() async throws {
        let navigation = try await makeNavigation()
        for destination in [LocalFavoritesDestination.updates, .boardFavorites, .syncProgress] {
            switch destination {
            case .updates: navigation.routes.isUpdatesPagePushed = true
            case .boardFavorites: navigation.routes.isBoardFavoritesPushed = true
            case .syncProgress: navigation.routes.isSyncProgressPushed = true
            default: XCTFail("Unexpected test destination")
            }
            XCTAssertEqual(navigation.path, [destination])
            navigation.binding.wrappedValue = []
            XCTAssertTrue(navigation.path.isEmpty)
            XCTAssertEqual(navigation.organizer.selectedCategoryID, FavoriteCategory.defaultID)
        }
    }

    func testRootDetailAndReaderDoNotChangeFavoritesTabOrPath() async throws {
        let navigation = try await makeNavigation()
        let detail = ContentDetailDestination.manga(.init(thread: .init(tid: "501"), title: "Work"))
        navigation.routes.detail = detail
        XCTAssertTrue(navigation.navigator.path.isEmpty)
        let path = navigation.path
        let appModel = navigation.navigator.appModel
        let originalTab = appModel.selectedTab
        appModel.presentMangaReader(.init(originalThreadID: "501", chapterTID: "501", displayTitle: "Work", source: .favorites))
        XCTAssertEqual(navigation.path, path)
        XCTAssertEqual(appModel.selectedTab, originalTab)
        navigation.path = []
        XCTAssertTrue(navigation.navigator.path.isEmpty)
        XCTAssertNil(navigation.routes.detail)
    }

    private func makeNavigation() async throws -> LocalFavoritesNavigation {
        let fixture = try makeSystemSettingsFixture()
        let dependencies = fixture.appContext.libraryDependencies
        let organizer = FavoriteLibraryOrganizer(
            libraryStore: dependencies.localFavoriteLibraryStore,
            readingProgressStore: dependencies.readingProgressStore,
            settingsStore: dependencies.settingsStore,
            contentCoverStore: dependencies.contentCoverStore,
            favoriteBackgroundImageStore: dependencies.favoriteBackgroundImageStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            makeFavoriteRepository: dependencies.makeFavoriteRepository
        )
        await organizer.load()
        let appModel = YamiboAppModel(appContext: fixture.appContext)
        return LocalFavoritesNavigation(
            organizer: organizer,
            routes: LocalFavoritesRoutes(),
            navigator: ForumDestinationNavigator(dependencies: fixture.appContext.forumDependencies, appModel: appModel, mode: .contentBrowser)
        )
    }
}

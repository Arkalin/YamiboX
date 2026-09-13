import SwiftUI
import Testing
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
@Test func localFavoritesOrganizationViewIsConstructibleWithNativeOrganizationData() async throws {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-organization-view")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let libraryStore = FavoriteLibraryStore(defaults: defaults, key: "local-favorites")
    let readingProgressStore = ReadingProgressStore(defaults: defaults, key: "reading-progress")
    let settingsStore = SettingsStore(defaults: defaults, key: "settings")
    let contentCoverStore = ContentCoverStore(defaults: defaults, key: "content-covers")
    let favoriteUpdateStore = FavoriteUpdateStore(defaults: defaults, key: "favorite-updates")
    let sessionStore = SessionStore(defaults: defaults, key: "session")
    let urlSession = YamiboNetworkConfiguration.makeSession()
    let forumCacheStore = ForumCacheStore(
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    )
    let favoriteBackgroundImageStore = FavoriteBackgroundImageStore(
        baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    )
    @Sendable func makeClient() async -> YamiboClient {
        let sessionState = await sessionStore.load()
        return YamiboClient(session: urlSession, cookie: sessionState.cookie, userAgent: sessionState.userAgent)
    }

    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "分类")
    let collection = document.createCollection(categoryID: category.id, name: "合集", color: .blue)
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "801")
    let item = try FavoriteItem(
        target: target,
        title: "主题",
        sourceGroup: .forumBoard(id: "fid", label: "版块"),
        locations: [.category(category.id), .collection(categoryID: category.id, collectionID: collection.id)]
    )
    document.upsertItem(item)
    try await libraryStore.save(document)

    let organizer = FavoriteLibraryOrganizer(
        libraryStore: libraryStore,
        readingProgressStore: readingProgressStore,
        settingsStore: settingsStore,
        contentCoverStore: contentCoverStore,
        favoriteBackgroundImageStore: favoriteBackgroundImageStore,
        makeFavoriteRepository: { FavoriteRepository(client: await makeClient()) }
    )
    let remoteSync = FavoriteRemoteSyncSession(
        libraryStore: libraryStore,
        runStore: FavoriteSyncRunStore(defaults: defaults, key: "sync-runs"),
        contentCoverStore: contentCoverStore,
        makeFavoriteRepository: { FavoriteRepository(client: await makeClient()) },
        makeForumThreadReaderRepository: { ForumThreadReaderRepository(client: await makeClient(), cacheStore: forumCacheStore) },
        makeThreadRouteResolver: { YamiboThreadRouteResolver(client: await makeClient()) }
    )
    let updateMonitor = FavoriteUpdateMonitor(
        updateStore: favoriteUpdateStore,
        libraryStore: libraryStore,
        makeForumThreadReaderRepository: { ForumThreadReaderRepository(client: await makeClient(), cacheStore: forumCacheStore) }
    )

    let appContext = try makeSystemSettingsFixture().appContext
    let view = LocalFavoritesOrganizationView(
        organizer: organizer,
        navigator: ForumDestinationNavigator(
            dependencies: appContext.forumDependencies,
            appModel: YamiboAppModel(appContext: appContext),
            mode: .contentBrowser
        ),
        routes: LocalFavoritesRoutes(),
        detailScreen: { destination in
            ContentDetailScreen(
                destination: destination,
                novelDependencies: appContext.novelDetailDependencies,
                mangaDependencies: appContext.mangaDetailDependencies,
                onAction: { _ in }
            )
        },
        isBookPresented: false,
        favoriteShare: FavoriteShareFlowModel(
            service: FavoriteShareService(
                libraryStore: libraryStore,
                contentCoverStore: contentCoverStore,
                settingsStore: settingsStore
            )
        ),
        remoteSync: remoteSync,
        updateMonitor: updateMonitor,
        makeFavoriteRepository: { FavoriteRepository(client: await makeClient()) },
        onOpen: { _, _, _, _ in },
        onOpenMangaDirectory: { _ in },
        onOpenBoard: { _ in }
    )
    _ = view

    await organizer.load()
    #expect(view.browseNavigationTitle(usesSidebar: true) == FavoriteCategory.defaultCategory.displayName)
    organizer.selectedCategoryID = category.id
    #expect(view.browseNavigationTitle(usesSidebar: true) == category.displayName)
    #expect(view.browseNavigationTitle(usesSidebar: false) == L10n.string("favorites.title"))

    #expect(organizer.derived.cards.map(\.id) == [item.id])
    #expect(organizer.derived.visibleCollections.map(\.id) == [collection.id])

    organizer.selection.enterSelectionMode()
    #expect(view.browseNavigationTitle(usesSidebar: true) == L10n.string("favorites.selected_count", 0))
    organizer.selection.exitSelectionMode()
    #expect(view.browseNavigationTitle(usesSidebar: true) == category.displayName)
    organizer.selectedCategoryID = FavoriteCategory.defaultID
    #expect(view.browseNavigationTitle(usesSidebar: true) == FavoriteCategory.defaultCategory.displayName)
}

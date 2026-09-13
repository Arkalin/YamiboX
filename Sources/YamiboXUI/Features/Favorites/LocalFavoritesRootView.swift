import SwiftUI
import YamiboXCore

/// Composition root for the favorites tab: creates the library organizer,
/// the remote sync session, and the update monitor, and routes resolved open
/// targets into the app-level readers or a full-screen thread overlay.
struct LocalFavoritesRootView: View {
    @State private var organizer: FavoriteLibraryOrganizer
    @State private var favoriteShare: FavoriteShareFlowModel
    @StateObject private var remoteSync: FavoriteRemoteSyncSession
    @StateObject private var updateMonitor: FavoriteUpdateMonitor
    @State private var threadOverlayItem: ForumThreadOverlayItem?
    @State private var threadOpeningTransition: BookOpeningTransition?
    @State private var isThreadCoverVisible = false
    @State private var isOpeningFavorite = false
    @State private var navigator: ForumDestinationNavigator
    @StateObject private var routes = LocalFavoritesRoutes()

    private let openTargetResolver: LocalFavoriteOpenTargetResolver
    private let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    let appModel: YamiboAppModel

    init(dependencies: LibraryDependencies, appModel: YamiboAppModel) {
        _navigator = State(initialValue: ForumDestinationNavigator(
            dependencies: appModel.appContext.forumDependencies,
            appModel: appModel,
            mode: .contentBrowser
        ))
        _organizer = State(initialValue: FavoriteLibraryOrganizer(
            libraryStore: dependencies.localFavoriteLibraryStore,
            readingProgressStore: dependencies.readingProgressStore,
            settingsStore: dependencies.settingsStore,
            contentCoverStore: dependencies.contentCoverStore,
            favoriteBackgroundImageStore: dependencies.favoriteBackgroundImageStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            makeForumThreadReaderRepository: dependencies.makeForumThreadReaderRepository,
            makeFavoriteRepository: dependencies.makeFavoriteRepository
        ))
        _favoriteShare = State(initialValue: FavoriteShareFlowModel(
            service: FavoriteShareService(
                libraryStore: dependencies.localFavoriteLibraryStore,
                contentCoverStore: dependencies.contentCoverStore,
                settingsStore: dependencies.settingsStore
            )
        ))
        _remoteSync = StateObject(wrappedValue: FavoriteRemoteSyncSession(
            libraryStore: dependencies.localFavoriteLibraryStore,
            runStore: dependencies.favoriteSyncRunStore,
            contentCoverStore: dependencies.contentCoverStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore,
            makeFavoriteRepository: dependencies.makeFavoriteRepository,
            makeForumThreadReaderRepository: dependencies.makeForumThreadReaderRepository,
            makeThreadRouteResolver: dependencies.makeThreadRouteResolver
        ))
        _updateMonitor = StateObject(wrappedValue: FavoriteUpdateMonitor(
            updateStore: dependencies.favoriteUpdateStore,
            libraryStore: dependencies.localFavoriteLibraryStore,
            makeForumThreadReaderRepository: dependencies.makeForumThreadReaderRepository,
            settingsStore: dependencies.settingsStore,
            notifier: UserNotificationFavoriteUpdateNotifier(),
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            makeMangaDirectoryWorkflow: { searchForumID in
                MangaDirectoryWorkflow(
                    repository: await dependencies.makeMangaDirectoryRepository(),
                    store: dependencies.mangaDirectoryStore,
                    configuration: MangaDirectoryWorkflowConfiguration(searchForumID: searchForumID),
                    searchCooldownState: dependencies.mangaDirectorySearchCooldownState
                )
            }
        ))
        openTargetResolver = LocalFavoriteOpenTargetResolver(
            libraryStore: dependencies.localFavoriteLibraryStore,
            readingProgressStore: dependencies.readingProgressStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore
        )
        makeFavoriteRepository = dependencies.makeFavoriteRepository
        self.appModel = appModel
    }

    var body: some View {
        LocalFavoritesOrganizationView(
            organizer: organizer,
            navigator: navigator,
            routes: routes,
            detailScreen: detailScreen,
            isBookPresented: appModel.isReaderCoverVisible || isThreadCoverVisible,
            favoriteShare: favoriteShare,
            remoteSync: remoteSync,
            updateMonitor: updateMonitor,
            makeFavoriteRepository: makeFavoriteRepository,
            onOpen: { item, mode, mangaScope, transition in
                await open(item, mode: mode, mangaScope: mangaScope, transition: transition)
            },
            onOpenMangaDirectory: { cleanBookName in
                await openMangaDirectoryEvent(cleanBookName: cleanBookName)
            },
            onOpenBoard: { board in
                appModel.openForumURL(
                    YamiboRoute.forumBoard(fid: board.fid, page: 1, filterID: nil, orderFilter: nil, orderBy: nil).url
                )
            }
        )
        .fullScreenCover(item: $threadOverlayItem, onDismiss: { isThreadCoverVisible = false }) { item in
            BookOpeningDestination(source: threadOpeningTransition) {
                ForumThreadOverlayScreen(
                    item: item,
                    dependencies: appModel.appContext.forumDependencies,
                    appModel: appModel,
                    // Opening a favorite is a real visit, not a discussion
                    // companion of a running reader; it records history.
                    rootIsDiscussionView: false
                )
            }
        }
        .onChange(of: appModel.isReaderCoverVisible || isThreadCoverVisible || routes.detail != nil, initial: true) { _, visible in
            organizer.setBookPresentationActive(visible)
        }
        .task {
            async let organizerLoad: Void = organizer.load()
            async let remoteSyncLoad: Void = remoteSync.load()
            async let updateMonitorLoad: Void = updateMonitor.load()
            _ = await (organizerLoad, remoteSyncLoad, updateMonitorLoad)
            // Foreground catch-up for automatic update checking: background
            // refresh timing is only best-effort. A larger non-tag directory
            // cap than the background task's is safe here — this runs while
            // the user is actively looking at the screen, not against a
            // BGAppRefreshTask's tight execution budget.
            await updateMonitor.startCheckIfDue(nonTagMangaDirectoryCheckCap: 3)
        }
    }

    private func open(
        _ item: FavoriteItem,
        mode: FavoriteLaunchMode,
        mangaScope: FavoriteMangaReadingScope,
        transition: BookOpeningTransition?
    ) async {
        guard !isOpeningFavorite, !appModel.isReaderCoverVisible else { return }
        isOpeningFavorite = true
        defer { isOpeningFavorite = false }
        do {
            guard let target = try await openTargetResolver.openTarget(for: item, mode: mode, mangaScope: mangaScope) else { return }
            guard !Task.isCancelled else { return }
            await present(target, transition: transition)
        } catch {
            YamiboLog.library.error("Failed to resolve open target for favorite \(item.id): \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                organizer.errorMessage = error.localizedDescription
                organizer.errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    /// Re-derives and opens a smart-manga update event's target from its
    /// `cleanBookName` alone (a directory-mode event carries no pointer to
    /// one specific favorite — see `FavoriteUpdateTargetKey.mangaDirectory`).
    private func openMangaDirectoryEvent(cleanBookName: String) async {
        do {
            guard let target = try await openTargetResolver.openTarget(forMangaDirectoryCleanBookName: cleanBookName) else {
                organizer.transientFeedback = .failure(L10n.string("favorites.updates.event_target_missing"))
                return
            }
            await present(target)
        } catch {
            YamiboLog.library.error("Failed to resolve open target for manga directory update \(cleanBookName): \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                organizer.errorMessage = error.localizedDescription
                organizer.errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    private func present(_ target: LocalFavoriteOpenTarget, transition: BookOpeningTransition? = nil) async {
        switch target {
        case let .novelDetail(context):
            routes.detail = .novel(context)
        case let .mangaDetail(context):
            routes.detail = .manga(context)
        case let .novelReader(context):
            appModel.presentNovelReader(context, bookOpeningTransition: transition)
        case let .mangaReader(context):
            await appModel.requestMangaReader(context, bookOpeningTransition: transition).value
        case let .nativeThread(url, title):
            // Plain-post favorites open in a full-screen overlay so the
            // favorites tab stays put underneath, mirroring the reader's
            // 打开原帖 behavior.
            threadOpeningTransition = transition
            isThreadCoverVisible = true
            threadOverlayItem = ForumThreadOverlayItem(url: url, title: title)
        }
    }

    private func detailScreen(_ destination: ContentDetailDestination) -> ContentDetailScreen {
        ContentDetailScreen(
            destination: destination,
            novelDependencies: appModel.appContext.novelDetailDependencies,
            mangaDependencies: appModel.appContext.mangaDetailDependencies
        ) { action in
            switch action {
            case let .readNovel(context, transition): appModel.presentNovelReader(context, bookOpeningTransition: transition)
            case let .readManga(context, transition): appModel.requestMangaReader(context, bookOpeningTransition: transition)
            case let .author(uid, name): navigator.openUserSpace(uid: uid, name: name)
            case let .discussion(context): navigator.push(.threadReader(context))
            }
        }
    }
}

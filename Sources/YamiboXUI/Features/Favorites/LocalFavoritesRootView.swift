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
    private let makeFavoriteRepository: @Sendable () async -> any BoardFavoriteManaging
    private let forumDependencies: ForumNavigationDependencies
    let appModel: YamiboAppModel

    init(dependencies: LibraryDependencies, forumDependencies: ForumNavigationDependencies, appModel: YamiboAppModel) {
        self.forumDependencies = forumDependencies
        _navigator = State(initialValue: ForumDestinationNavigator(
            dependencies: forumDependencies,
            actions: appModel.forumNavigationActions,
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
        _updateMonitor = StateObject(wrappedValue: FavoriteUpdateMonitor.makeForLibrary(dependencies))
        openTargetResolver = LocalFavoriteOpenTargetResolver(
            libraryStore: dependencies.localFavoriteLibraryStore,
            readingProgressStore: dependencies.readingProgressStore,
            mangaDirectoryStore: dependencies.mangaDirectoryStore,
            settingsStore: dependencies.settingsStore
        )
        makeFavoriteRepository = dependencies.makeFavoriteRepository
        self.appModel = appModel
    }

    private var unreadIndex: FavoriteUnreadIndex {
        FavoriteUnreadIndex(
            items: organizer.favoriteItems,
            directories: organizer.unreadMangaDirectoriesByTID,
            events: updateMonitor.events
        )
    }

    var body: some View {
        LocalFavoritesOrganizationView(
            organizer: organizer,
            navigator: navigator,
            forumScreen: { ForumDestinationScreen(destination: $0, navigator: navigator, appModel: appModel) },
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
            onOpenMangaDirectory: { directoryID in
                await openMangaDirectoryEvent(directoryID: directoryID)
            },
            onOpenBoard: { board in
                appModel.openForumURL(
                    YamiboRoute.forumBoard(fid: board.fid, page: 1, filterID: nil, orderFilter: nil, orderBy: nil).url
                )
            }
        )
        .environment(\.favoriteUnreadIndex, unreadIndex)
        .environmentObject(updateMonitor)
        .fullScreenCover(item: $threadOverlayItem, onDismiss: { isThreadCoverVisible = false }) { item in
            BookOpeningDestination(source: threadOpeningTransition) {
                ForumThreadOverlayScreen(
                    item: item,
                    dependencies: forumDependencies,
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
        .onChange(of: appModel.favoriteUpdatesRequestID, initial: true) { _, _ in
            guard appModel.claimFavoriteUpdatesRequest() else { return }
            routes.isUpdatesPagePushed = true
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
        let unreadEventIDs = unreadIndex.favorites[item.id, default: []]
        do {
            guard let target = try await openTargetResolver.openTarget(for: item, mode: mode, mangaScope: mangaScope) else { return }
            guard !Task.isCancelled else { return }
            guard await present(target, transition: transition), !Task.isCancelled else { return }
            await updateMonitor.markEventsRead(unreadEventIDs)
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
    private func openMangaDirectoryEvent(directoryID: MangaDirectoryID) async {
        guard !isOpeningFavorite, !appModel.isReaderCoverVisible else { return }
        isOpeningFavorite = true
        defer { isOpeningFavorite = false }
        let unreadEventIDs = Set(updateMonitor.events.filter {
            $0.target == .mangaDirectory(directoryID: directoryID) && $0.readAt == nil
        }.map(\.id))
        do {
            guard let target = try await openTargetResolver.openTarget(forMangaDirectoryID: directoryID) else {
                organizer.transientFeedback = .failure(L10n.string("favorites.updates.event_target_missing"))
                return
            }
            guard !Task.isCancelled else { return }
            guard await present(target), !Task.isCancelled else { return }
            await updateMonitor.markEventsRead(unreadEventIDs)
        } catch {
            YamiboLog.library.error("Failed to resolve open target for manga directory update \(directoryID.rawValue): \(error.localizedDescription)")
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                organizer.errorMessage = error.localizedDescription
                organizer.errorDetails = LoadFailureDetails(error: error)
            }
        }
    }

    private func present(_ target: LocalFavoriteOpenTarget, transition: BookOpeningTransition? = nil) async -> Bool {
        switch target {
        case let .novelDetail(context):
            routes.detail = .novel(context)
        case let .mangaDetail(context):
            routes.detail = .manga(context)
        case let .novelReader(context):
            appModel.presentNovelReader(context, bookOpeningTransition: transition)
        case let .mangaReader(context):
            await appModel.requestMangaReader(context, bookOpeningTransition: transition).value
            // Manga validation can fail after target resolution without ever
            // presenting a reader. Acknowledgement requires this actual launch.
            guard let session = appModel.presentedReaderSession, !session.isClosed,
                  case let .manga(openedContext) = session.content else { return false }
            return openedContext == context
        case let .nativeThread(url, title):
            // Plain-post favorites open in a full-screen overlay so the
            // favorites tab stays put underneath, mirroring the reader's
            // 打开原帖 behavior.
            threadOpeningTransition = transition
            isThreadCoverVisible = true
            threadOverlayItem = ForumThreadOverlayItem(url: url, title: title)
        }
        return true
    }

    private func detailScreen(_ destination: ContentDetailDestination) -> ContentDetailScreen {
        ContentDetailScreen(
            destination: destination,
            novelDependencies: forumDependencies.destinations.novelDetail,
            mangaDependencies: forumDependencies.destinations.mangaDetail
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

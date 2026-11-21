import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YamiboXCore

enum LocalFavoritePresentationScope: Equatable {
    case libraryRoot
    case collection
    case mangaArchive

    var showsCategoryTabBar: Bool { self == .libraryRoot }
}

struct LocalFavoritesOrganizationView: View {
    @Bindable var organizer: FavoriteLibraryOrganizer
    let navigator: ForumDestinationNavigator
    let forumScreen: (ForumDestination) -> ForumDestinationScreen
    @Bindable var favoriteShare: FavoriteShareFlowModel
    @ObservedObject var remoteSync: FavoriteRemoteSyncSession
    @ObservedObject var updateMonitor: FavoriteUpdateMonitor
    @ObservedObject private var selection: LocalFavoriteBrowseSession
    @ObservedObject private var routes: LocalFavoritesRoutes
    @State private var updateEventScopeCache = FavoriteUpdateEventScopeCache()
    let detailScreen: (ContentDetailDestination) -> ContentDetailScreen
    let isBookPresented: Bool

    let onOpen: (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope, BookOpeningTransition?) async -> Void
    let onOpenMangaDirectory: (MangaDirectoryID) async -> Void
    let makeFavoriteRepository: @Sendable () async -> any BoardFavoriteManaging
    let onOpenBoard: (BoardFavorite) -> Void

    init(
        organizer: FavoriteLibraryOrganizer,
        navigator: ForumDestinationNavigator,
        forumScreen: @escaping (ForumDestination) -> ForumDestinationScreen,
        routes: LocalFavoritesRoutes,
        detailScreen: @escaping (ContentDetailDestination) -> ContentDetailScreen,
        isBookPresented: Bool,
        favoriteShare: FavoriteShareFlowModel,
        remoteSync: FavoriteRemoteSyncSession,
        updateMonitor: FavoriteUpdateMonitor,
        makeFavoriteRepository: @escaping @Sendable () async -> any BoardFavoriteManaging,
        onOpen: @escaping (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope, BookOpeningTransition?) async -> Void,
        onOpenMangaDirectory: @escaping (MangaDirectoryID) async -> Void,
        onOpenBoard: @escaping (BoardFavorite) -> Void
    ) {
        self.organizer = organizer
        self.navigator = navigator
        self.forumScreen = forumScreen
        self.routes = routes
        self.detailScreen = detailScreen
        self.isBookPresented = isBookPresented
        self.favoriteShare = favoriteShare
        self.remoteSync = remoteSync
        self.updateMonitor = updateMonitor
        self.selection = organizer.selection
        self.onOpen = onOpen
        self.onOpenMangaDirectory = onOpenMangaDirectory
        self.makeFavoriteRepository = makeFavoriteRepository
        self.onOpenBoard = onOpenBoard
    }

    var body: some View {
        LocalFavoritesAdaptiveNavigation(organizer: organizer, routes: routes, navigator: navigator) {
            browseStack
        }
    }

    private var browseStack: some View {
        NavigationStack(path: LocalFavoritesNavigation(organizer: organizer, routes: routes, navigator: navigator).binding) {
            backgrounded {
                content(derived: organizer.rootDerived, scope: .libraryRoot)
                    .overlay { emptyStateOverlay(derived: organizer.rootDerived, scope: .libraryRoot) }
            }
            .navigationTitle(browseNavigationTitle(usesSidebar: UIDevice.current.userInterfaceIdiom == .pad))
            .navigationBarTitleDisplayMode(.inline)
            .modifier(LocalFavoriteBrowseSearch(
                organizer: organizer,
                isActive: keyboardCommandsEnabled && organizer.isBrowsingUnscopedRoot
            ))
            .toolbar { favoriteToolbarContent }
            .toolbar(selection.isSelectionMode ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if selection.isSelectionMode && !usesSystemSelectionBottomToolbar {
                    LocalFavoriteSelectionActionBar(
                        organizer: organizer,
                        selection: selection,
                        routes: routes
                    )
                    .selectionBottomToolbarCapsule()
                }
            }
            .safeAreaInset(edge: .top) {
                if showsTopStatusCards {
                    statusCards
                }
            }
            .failureAlert(
                L10n.string("common.operation_failed"),
                message: combinedErrorMessage,
                details: combinedErrorDetails,
                isPresented: errorAlertBinding
            ) {
                Button(L10n.string("common.ok")) {
                    clearErrorMessages()
                }
            }
            .alert(
                dialogTitle,
                isPresented: dialogBinding,
                presenting: routes.dialog,
                actions: dialogActions,
                message: dialogMessage
            )
            .favoriteRemovePromptDialog(prompt: $organizer.removeRemotePrompt) { prompt, removeRemote, remember in
                Task { await organizer.confirmRemoveRemotePrompt(prompt, removeRemote: removeRemote, remember: remember) }
            }
            .sheet(item: $routes.sheet) { sheet in
                LocalFavoritesSheetContent(
                    sheet: sheet,
                    organizer: organizer,
                    favoriteShare: favoriteShare,
                    remoteSync: remoteSync,
                    updateMonitor: updateMonitor,
                    routes: routes
                )
            }
            .fileImporter(
                isPresented: $favoriteShare.isFileImporterPresented,
                allowedContentTypes: [.item]
            ) { result in
                switch result {
                case let .success(url):
                    Task {
                        if await favoriteShare.loadImportFile(url) {
                            routes.sheet = .favoriteShareImportPreview
                        }
                    }
                case let .failure(error):
                    favoriteShare.handleImporterFailure(error)
                }
            }
            .fileExporter(
                isPresented: $favoriteShare.isFileExporterPresented,
                document: FavoriteShareFileDocument(data: favoriteShare.preparedExport?.data ?? Data()),
                contentType: .json,
                defaultFilename: favoriteShare.preparedExport?.fileName ?? "yamibo-favorites.json",
                onCompletion: favoriteShare.handleExporterResult
            )
            .transientMessage(TransientFeedback.latest(favoriteShare.transientFeedback, organizer.transientFeedback)) {
                favoriteShare.transientMessage = nil
                organizer.transientMessage = nil
            }
            .navigationDestination(for: LocalFavoritesDestination.self, destination: destinationView)
            #if DEBUG
            .onChange(of: organizer.rootDerived, initial: true) { _, derived in
                guard ProcessInfo.processInfo.environment["START_FAVORITES_SELECTION"] == "1",
                      !selection.isSelectionMode,
                      let firstCard = derived.cards.first else { return }
                selection.toggleFavoriteSelection(id: firstCard.id)
            }
            #endif
        }
        .transientMessage(navigator.transientFeedback) { navigator.transientFeedback = nil }
    }

    func browseNavigationTitle(usesSidebar: Bool) -> String {
        if selection.isSelectionMode {
            return L10n.string("favorites.selected_count", selection.selectedEntryCount)
        }
        guard usesSidebar else { return L10n.string("favorites.title") }
        return (organizer.categories.first { $0.id == organizer.selectedCategoryID }
            ?? .defaultCategory).displayName
    }

    @ViewBuilder
    private func destinationView(_ destination: LocalFavoritesDestination) -> some View {
        switch destination {
        case .collection:
            collectionDetail
        case .mergedGroup:
            mergedGroupDetail
        case let .forum(route):
            forumScreen(route)
        case let .detail(destination):
            detailScreen(destination)
        case .updates:
            FavoriteUpdatesPage(
                updateMonitor: updateMonitor,
                routes: routes,
                eventScope: { scopedUpdateEvents },
                onOpen: { event in
                    switch event.target {
                    case .favorite:
                        guard let item = organizer.favoriteItems.first(where: { $0.target.id == event.target.id }) else {
                            organizer.transientFeedback = .failure(L10n.string("favorites.updates.event_target_missing"))
                            return
                        }
                        await onOpen(item, .resume, .boardDefault, nil)
                    case let .mangaDirectory(directoryID):
                        await onOpenMangaDirectory(directoryID)
                    }
                }
            )
            .toolbar(selection.isSelectionMode ? .hidden : .automatic, for: .tabBar)
        case .boardFavorites:
            FavoriteBoardListView(
                model: FavoriteBoardListViewModel(repositoryProvider: makeFavoriteRepository),
                onOpenBoard: onOpenBoard
            )
            .toolbar(selection.isSelectionMode ? .hidden : .automatic, for: .tabBar)
        case .syncProgress:
            FavoriteRemoteSyncProgressSheet(
                snapshot: remoteSync.snapshot,
                onResume: {
                    await remoteSync.resume()
                },
                onInterrupt: {
                    await remoteSync.interrupt()
                },
                onHide: {
                    await remoteSync.hideCard()
                },
                showsCloseButton: false
            )
            .toolbar(selection.isSelectionMode ? .hidden : .automatic, for: .tabBar)
        }
    }


    private var collectionDetail: some View {
        backgrounded {
            content(derived: organizer.derived, scope: .collection)
                .overlay { emptyStateOverlay(derived: organizer.derived, scope: .collection) }
        }
        .modifier(LocalFavoriteBrowseSearch(
            organizer: organizer,
            isActive: keyboardCommandsEnabled && organizer.selectedCollectionID != nil
                && organizer.selectedMergedGroupKey == nil
        ))
        .navigationTitle(
            selection.isSelectionMode
                ? L10n.string("favorites.selected_count", selection.selectedEntryCount)
                : (organizer.selectedCollection?.name ?? "")
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selection.isSelectionMode)
        .toolbar {
            if selection.isSelectionMode {
                selectionToolbarContent
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    collectionDetailMenu
                }
            }
        }
        .toolbar(selection.isSelectionMode ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if selection.isSelectionMode && !usesSystemSelectionBottomToolbar {
                LocalFavoriteSelectionActionBar(
                    organizer: organizer,
                    selection: selection,
                    routes: routes
                )
                .selectionBottomToolbarCapsule()
            }
        }
        .transientMessage(organizer.transientFeedback) {
            organizer.transientMessage = nil
        }
    }

    @ViewBuilder
    private var collectionDetailMenu: some View {
        if let collection = organizer.selectedCollection {
            Menu {
                Button {
                    routes.sheet = .collectionEditor(LocalFavoriteCollectionDraft(collection: collection))
                } label: {
                    Label(L10n.string("common.edit"), systemImage: "pencil")
                }
                Button {
                    selection.enterSelectionMode()
                } label: {
                    Label(L10n.string("common.select"), systemImage: "checkmark.circle")
                }
                Menu {
                    ForEach(organizer.categories.manualOrderSorted) { category in
                        Button {
                            Task { await organizer.moveCollection(id: collection.id, toCategoryID: category.id) }
                        } label: {
                            if category.id == collection.categoryID {
                                Label(category.displayName, systemImage: "checkmark")
                            } else {
                                Text(category.displayName)
                            }
                        }
                        .disabled(category.id == collection.categoryID)
                    }
                } label: {
                    Label(L10n.string("favorites.category.select"), systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    routes.dialog = .dissolveCollection(collection)
                } label: {
                    Label(L10n.string("favorites.dissolve"), systemImage: "folder.badge.minus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(L10n.string("common.more"))
        }
    }


    private var mergedGroupDetail: some View {
        backgrounded {
            content(derived: organizer.derived, scope: .mangaArchive)
                .overlay { emptyStateOverlay(derived: organizer.derived, scope: .mangaArchive) }
        }
        .modifier(LocalFavoriteBrowseSearch(
            organizer: organizer,
            isActive: keyboardCommandsEnabled && organizer.selectedMergedGroupKey != nil
        ))
        .navigationTitle(
            selection.isSelectionMode
                ? L10n.string("favorites.selected_count", selection.selectedEntryCount)
                : (organizer.selectedMergedGroupTitle ?? "")
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selection.isSelectionMode)
        .toolbar {
            if selection.isSelectionMode {
                selectionToolbarContent
            }
        }
        .toolbar(selection.isSelectionMode ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if selection.isSelectionMode && !usesSystemSelectionBottomToolbar {
                LocalFavoriteSelectionActionBar(
                    organizer: organizer,
                    selection: selection,
                    routes: routes
                )
                .selectionBottomToolbarCapsule()
            }
        }
        .transientMessage(organizer.transientFeedback) {
            organizer.transientMessage = nil
        }
    }


    private var keyboardCommandsEnabled: Bool {
        !isBookPresented && routes.sheet == nil && routes.dialog == nil && routes.detail == nil
            && !routes.isUpdatesPagePushed && !routes.isBoardFavoritesPushed && !routes.isSyncProgressPushed
            && navigator.path.isEmpty && organizer.removeRemotePrompt == nil
            && !favoriteShare.isFileImporterPresented && !favoriteShare.isFileExporterPresented
            && combinedErrorMessage == nil
    }

    private func backgrounded(@ViewBuilder _ content: () -> some View) -> some View {
        LocalFavoritesBackground(
            settings: organizer.backgroundSettings,
            imageData: organizer.backgroundImageData,
            content: content
        )
    }

    @ViewBuilder
    private func content(derived: LocalFavoriteDerivedState, scope: LocalFavoritePresentationScope) -> some View {
        switch organizer.display.layoutMode {
        case .rowCard:
            LocalFavoriteListContent(
                organizer: organizer,
                selection: selection,
                routes: routes,
                showsCover: true,
                derived: derived,
                scope: scope,
                onOpen: onOpen
            )
        case .rowCardText:
            LocalFavoriteListContent(
                organizer: organizer,
                selection: selection,
                routes: routes,
                showsCover: false,
                derived: derived,
                scope: scope,
                onOpen: onOpen
            )
        case .fixedGrid:
            LocalFavoriteGridContent(
                organizer: organizer,
                selection: selection,
                routes: routes,
                isStaggered: false,
                derived: derived,
                scope: scope,
                onOpen: onOpen
            )
        case .staggered:
            LocalFavoriteGridContent(
                organizer: organizer,
                selection: selection,
                routes: routes,
                isStaggered: true,
                derived: derived,
                scope: scope,
                onOpen: onOpen
            )
        }
    }


    private var showsTopStatusCards: Bool {
        guard let snapshot = remoteSync.snapshot else { return false }
        return !snapshot.isHiddenFromFavoritePage
    }

    private var unreadUpdateCount: Int {
        scopedUpdateEvents.unreadCount
    }

    private var scopedUpdateEvents: FavoriteUpdateEventScope {
        updateEventScopeCache.value(
            revision: .init(
                organizer: ObjectIdentifier(organizer),
                monitor: ObjectIdentifier(updateMonitor),
                items: organizer.unreadItemsRevision,
                events: updateMonitor.eventsRevision,
                scope: updateMonitor.scopeRevision
            ),
            items: organizer.favoriteItems,
            events: updateMonitor.events,
            fidFilters: updateMonitor.fidFilters,
            categoryFilters: updateMonitor.categoryFilters,
            trackedTargets: updateMonitor.trackedTargets
        )
    }

    private var statusCards: some View {
        VStack(spacing: 8) {
            if let snapshot = remoteSync.snapshot, !snapshot.isHiddenFromFavoritePage {
                FavoriteRemoteSyncStatusCard(
                    snapshot: snapshot,
                    onOpen: {
                        routes.isSyncProgressPushed = true
                    },
                    onResume: {
                        Task {
                            if await remoteSync.resume() != nil {
                                routes.isSyncProgressPushed = true
                            }
                        }
                    },
                    onInterrupt: {
                        Task { await remoteSync.interrupt() }
                    },
                    onHide: {
                        Task { await remoteSync.hideCard() }
                    }
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }


    @ToolbarContentBuilder
    private var favoriteToolbarContent: some ToolbarContent {
        if selection.isSelectionMode {
            selectionToolbarContent
        } else {
            normalToolbarContent
        }
    }

    /// Selection mode: a select-all/clear-all toggle on the leading edge and
    /// a done button on the trailing edge (the bottom bar holds the
    /// actions). Cache-sheet select-all button parity: a single button whose
    /// label flips between "select all" and "invert" rather than a menu with
    /// two separate actions, and "invert" here just clears the selection
    /// (not a strict per-item inversion) since it only ever fires from an
    /// already-fully-selected state.
    ///
    /// No back button here even on the pushed collection/merged-group detail
    /// pages — `.navigationBarBackButtonHidden(selection.isSelectionMode)` on
    /// those pages suppresses `NavigationStack`'s automatic one, so this stays
    /// the only leading item instead of stacking a second arrow next to it.
    @ToolbarContentBuilder
    private var selectionToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            SelectAllToolbarButton(
                isSelectionComplete: organizer.isAllVisibleSelected,
                isDisabled: !organizer.hasVisibleSelectableEntries
            ) {
                organizer.toggleSelectAllVisible()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(L10n.string("common.done")) {
                selection.exitSelectionMode()
            }
            .fontWeight(.semibold)
        }
        if usesSystemSelectionBottomToolbar {
            ToolbarItem(placement: .bottomBar) {
                LocalFavoriteSelectionActionBar(
                    organizer: organizer,
                    selection: selection,
                    routes: routes
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var normalToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                routes.isUpdatesPagePushed = true
            } label: {
                Image(systemName: "bell")
                    .overlay(alignment: .topTrailing) {
                        if unreadUpdateCount > 0 {
                            Text("\(min(unreadUpdateCount, 99))")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 1.5)
                                .background(.red, in: Capsule())
                                .offset(x: 8, y: -6)
                        }
                    }
            }
            .accessibilityLabel(L10n.string("favorites.updates.title"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            favoriteMoreMenu
        }
    }

    private var favoriteMoreMenu: some View {
        Menu {
            Section {
                Button {
                    routes.isBoardFavoritesPushed = true
                } label: {
                    Label(L10n.string("favorites.boards.title"), systemImage: "square.grid.2x2")
                }
            }
            Section {
                Button {
                    routes.sheet = .categoryManagement
                } label: {
                    Label(L10n.string("favorites.category.manage"), systemImage: "slider.horizontal.3")
                }
                Button {
                    routes.sheet = .categoryName(LocalFavoriteCategoryNameDraft(mode: .create))
                } label: {
                    Label(L10n.string("favorites.category.create"), systemImage: "plus")
                }
                Button {
                    routes.sheet = .collectionEditor(LocalFavoriteCollectionDraft(mode: .create))
                } label: {
                    Label(L10n.string("favorites.create_collection"), systemImage: "folder.badge.plus")
                }
            }
            Section {
                Button {
                    selection.enterSelectionMode()
                } label: {
                    Label(L10n.string("common.select"), systemImage: "checkmark.circle")
                }
            }
            Section {
                Button {
                    favoriteShare.beginExport()
                    routes.sheet = .favoriteShareExportSelection
                } label: {
                    Label(L10n.string("favorites.share.action"), systemImage: "square.and.arrow.up")
                }
                Button {
                    favoriteShare.beginImport()
                } label: {
                    Label(L10n.string("favorites.share.load"), systemImage: "square.and.arrow.down")
                }
            }
            Section {
                Button {
                    if remoteSync.snapshot?.status == .running {
                        routes.isSyncProgressPushed = true
                    } else {
                        routes.sheet = .remoteSyncCategory
                    }
                } label: {
                    Label(L10n.string("favorites.sync.start"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("common.more"))
    }


    private var dialogBinding: Binding<Bool> {
        .presentation(
            isPresented: { routes.dialog != nil },
            identity: { routes.dialogIdentity },
            clearOnDismiss: { routes.dialog = nil }
        )
    }

    private var dialogTitle: Text {
        switch routes.dialog {
        case .dissolveCollection, .dissolveSelectedCollections:
            Text(L10n.string("favorites.dissolve_collection"))
        case .deleteItem:
            Text(L10n.string("favorites.delete_favorite"))
        case .deleteSelection:
            Text(L10n.string("favorites.delete_selection"))
        case nil:
            Text("")
        }
    }

    @ViewBuilder
    private func dialogActions(_ dialog: LocalFavoritesRoutes.Dialog) -> some View {
        switch dialog {
        case let .dissolveCollection(collection):
            Button(L10n.string("common.cancel"), role: .cancel) {}
            Button(L10n.string("favorites.dissolve"), role: .destructive) {
                Task { await organizer.dissolveCollection(id: collection.id) }
            }
        case let .deleteItem(item):
            Button(L10n.string("common.cancel"), role: .cancel) {}
            if item.locations.count > 1 {
                Button(L10n.string("favorites.delete_scope.current_location"), role: .destructive) {
                    Task { await organizer.requestDeleteItem(item, scope: .currentLocation) }
                }
            }
            Button(L10n.string("favorites.delete_scope.everywhere"), role: .destructive) {
                Task { await organizer.requestDeleteItem(item, scope: .everywhere) }
            }
        case let .deleteSelection(plan):
            Button(L10n.string("common.cancel"), role: .cancel) {}
            if plan.currentLocation != nil {
                Button(L10n.string("favorites.delete_scope.current_location"), role: .destructive) {
                    Task { await organizer.requestDeleteSelection(plan, scope: .currentLocation) }
                }
            }
            Button(L10n.string("favorites.delete_scope.everywhere"), role: .destructive) {
                Task { await organizer.requestDeleteSelection(plan, scope: .everywhere) }
            }
        case .dissolveSelectedCollections:
            Button(L10n.string("common.cancel"), role: .cancel) {}
            Button(L10n.string("favorites.dissolve"), role: .destructive) {
                Task { await organizer.dissolveSelectedCollections() }
            }
        }
    }

    @ViewBuilder
    private func dialogMessage(_ dialog: LocalFavoritesRoutes.Dialog) -> some View {
        switch dialog {
        case let .dissolveCollection(collection):
            Text(L10n.string("favorites.dissolve_collection_message", collection.name))
        case let .deleteItem(item):
            if item.locations.count > 1 {
                Text(deleteMessage(L10n.string("favorites.delete_favorite_scope_message", item.resolvedDisplayTitle)))
            } else {
                Text(deleteMessage(L10n.string("favorites.delete_favorite_message", item.resolvedDisplayTitle)))
            }
        case let .deleteSelection(plan):
            Text(deleteMessage(deleteSelectionMessage(plan), includesFavorites: !plan.items.isEmpty))
        case .dissolveSelectedCollections:
            Text(L10n.string("favorites.bulk_dissolve_collections_message"))
        }
    }

    private func deleteSelectionMessage(_ plan: LocalFavoriteSelectionDeletePlan) -> String {
        if !plan.collections.isEmpty {
            return L10n.string("favorites.bulk_delete_mixed_message")
        }
        if plan.currentLocation != nil {
            return L10n.string("favorites.bulk_delete_scope_message")
        }
        return L10n.string("favorites.bulk_delete_favorites_message")
    }

    private func deleteMessage(_ message: String, includesFavorites: Bool = true) -> String {
        guard includesFavorites else { return message }
        let outcomeKey: String
        if organizer.removeRemotePromptEnabled {
            outcomeKey = "favorites.delete_remote.prompt"
        } else if organizer.removeRemoteDefault {
            outcomeKey = "favorites.delete_remote.both"
        } else {
            outcomeKey = "favorites.delete_remote.local_only"
        }
        return message + "\n" + L10n.string(outcomeKey)
    }


    private var combinedErrorMessage: String? {
        favoriteShare.errorMessage ?? organizer.errorMessage ?? remoteSync.errorMessage ?? updateMonitor.errorMessage ?? navigator.actionErrorMessage
    }

    private var combinedErrorDetails: LoadFailureDetails? {
        let failures: [(String?, LoadFailureDetails?)] = [
            (favoriteShare.errorMessage, favoriteShare.errorDetails),
            (organizer.errorMessage, organizer.errorDetails),
            (remoteSync.errorMessage, remoteSync.errorDetails),
            (updateMonitor.errorMessage, updateMonitor.errorDetails),
            (navigator.actionErrorMessage, navigator.actionErrorDetails)
        ]
        let items = failures.compactMap { message, details -> LoadFailureDetails.Item? in
            guard let message else { return nil }
            return .init(title: message, details: details ?? LoadFailureDetails(message: message))
        }
        if items.count == 1 { return items[0].details }
        guard !items.isEmpty else { return nil }
        return LoadFailureDetails(message: combinedErrorMessage ?? "", failures: items)
    }

    private func clearErrorMessages() {
        favoriteShare.errorMessage = nil
        organizer.errorMessage = nil
        remoteSync.errorMessage = nil
        updateMonitor.errorMessage = nil
        navigator.actionErrorMessage = nil
    }

    private var errorAlertBinding: Binding<Bool> {
        .presentation(
            isPresented: { combinedErrorMessage != nil },
            identity: { [favoriteShare.errorIdentity, organizer.errorIdentity, remoteSync.errorIdentity, updateMonitor.errorIdentity, navigator.actionErrorIdentity] },
            clearOnDismiss: { clearErrorMessages() }
        )
    }

    @ViewBuilder
    private func emptyStateOverlay(derived: LocalFavoriteDerivedState, scope: LocalFavoritePresentationScope) -> some View {
        if derived.cards.isEmpty, scope != .libraryRoot || derived.visibleCollections.isEmpty {
            if hasSubmittedSearch {
                ContentUnavailableView(L10n.string("favorites.empty.no_results"), systemImage: "magnifyingglass")
            } else {
                switch scope {
                case .collection:
                    ContentUnavailableView(L10n.string("favorites.empty.collection"), systemImage: "folder")
                case .mangaArchive:
                    ContentUnavailableView(L10n.string("favorites.empty.manga_archive"), systemImage: "archivebox")
                case .libraryRoot:
                    ContentUnavailableView {
                        Label(L10n.string("favorites.empty.favorites"), systemImage: "books.vertical")
                    } description: {
                        Text(L10n.string("favorites.empty.sync_hint"))
                    }
                }
            }
        }
    }

    private var hasSubmittedSearch: Bool {
        !organizer.filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || organizer.filter.hasActiveFilters
    }
}

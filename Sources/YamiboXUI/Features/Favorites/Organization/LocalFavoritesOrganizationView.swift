import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YamiboXCore

/// Main favorites screen: navigation scaffold, toolbar, status cards, and
/// sheet/dialog presentation. Content rendering is delegated to the list and
/// grid content views, which read the organizer and browse session directly.
struct LocalFavoritesOrganizationView: View {
    @Bindable var organizer: FavoriteLibraryOrganizer
    let navigator: ForumDestinationNavigator
    @Bindable var favoriteShare: FavoriteShareFlowModel
    @ObservedObject var remoteSync: FavoriteRemoteSyncSession
    @ObservedObject var updateMonitor: FavoriteUpdateMonitor
    @ObservedObject private var selection: LocalFavoriteBrowseSession
    @ObservedObject private var routes: LocalFavoritesRoutes
    let detailScreen: (ContentDetailDestination) -> ContentDetailScreen
    let isBookPresented: Bool

    let onOpen: (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope, BookOpeningTransition?) async -> Void
    /// Opens a smart-manga update event by its `cleanBookName` alone — a
    /// directory-mode event carries no pointer to one specific favorite, so
    /// the open target must be re-derived fresh rather than looked up in
    /// `organizer.favoriteItems` the way `onOpen` above resolves a
    /// per-favorite event.
    let onOpenMangaDirectory: (String) async -> Void
    /// Feeds the pushed board-favorite page, which manages remote board
    /// favorites purely over the network (no local store involved).
    let makeFavoriteRepository: @Sendable () async -> FavoriteRepository
    let onOpenBoard: (BoardFavorite) -> Void

    init(
        organizer: FavoriteLibraryOrganizer,
        navigator: ForumDestinationNavigator,
        routes: LocalFavoritesRoutes,
        detailScreen: @escaping (ContentDetailDestination) -> ContentDetailScreen,
        isBookPresented: Bool,
        favoriteShare: FavoriteShareFlowModel,
        remoteSync: FavoriteRemoteSyncSession,
        updateMonitor: FavoriteUpdateMonitor,
        makeFavoriteRepository: @escaping @Sendable () async -> FavoriteRepository,
        onOpen: @escaping (FavoriteItem, FavoriteLaunchMode, FavoriteMangaReadingScope, BookOpeningTransition?) async -> Void,
        onOpenMangaDirectory: @escaping (String) async -> Void,
        onOpenBoard: @escaping (BoardFavorite) -> Void
    ) {
        self.organizer = organizer
        self.navigator = navigator
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
                content(derived: organizer.rootDerived, isCollectionDetail: false)
                    .overlay { emptyStateOverlay(derived: organizer.rootDerived, isCollectionDetail: false) }
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
            // Keep the debug selection hook independent of navigation changes.
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
            ForumDestinationScreen(destination: route, navigator: navigator)
        case let .detail(destination):
            detailScreen(destination)
        case .updates:
            FavoriteUpdatesPage(
                updateMonitor: updateMonitor,
                routes: routes,
                isEventVisible: isEventInFilterScope,
                onOpen: { event in
                    switch event.target {
                    case .favorite:
                        guard let item = organizer.favoriteItems.first(where: { $0.target.id == event.target.id }) else {
                            organizer.transientFeedback = .failure(L10n.string("favorites.updates.event_target_missing"))
                            return
                        }
                        await onOpen(item, .resume, .boardDefault, nil)
                    case let .mangaDirectory(cleanBookName):
                        await onOpenMangaDirectory(cleanBookName)
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

    // MARK: - Collection detail

    /// Opened collections push a detail page (iOS navigation instead of the
    /// Android in-place switch). The pushed page's content is scoped by the
    /// `organizer.derived` explicitly passed to it, not read ambiently,
    /// because `organizer.selectedCollectionID` only resets once the path
    /// binding's `set` fires (i.e. once the pop fully commits) — during an
    /// interactive edge-swipe-back gesture it stays non-nil for the whole
    /// drag, while the root screen underneath is already visible.
    private var collectionDetail: some View {
        backgrounded {
            content(derived: organizer.derived, isCollectionDetail: true)
                .overlay { emptyStateOverlay(derived: organizer.derived, isCollectionDetail: true) }
        }
        .modifier(LocalFavoriteBrowseSearch(
            organizer: organizer,
            isActive: keyboardCommandsEnabled && organizer.selectedCollectionID != nil
                && organizer.selectedMergedGroupCleanBookName == nil
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

    /// Collection actions in the detail page's toolbar (the in-content header
    /// is gone: the navigation bar already shows back and title).
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

    // MARK: - Merged smart-comic group detail

    /// Lists every individual favorite currently merged into the card that
    /// was opened — per-item management (delete/move/tag/etc.) happens here
    /// through the same single-item card UI every other favorite uses, since
    /// `LocalFavoriteLibraryProjection.cards(in:query:...)`'s
    /// `memberScopeCleanBookName` scoping deliberately builds each member as
    /// a genuinely standalone (non-merged) `FavoriteCardProjection`. Mirrors
    /// `collectionDetail` body-for-body, including reusing
    /// `isCollectionDetail: true` on `content(...)`/`emptyStateOverlay(...)`
    /// — that flag only affects the category tab bar and empty-state
    /// copy/icon, both of which read fine for this page too.
    private var mergedGroupDetail: some View {
        backgrounded {
            content(derived: organizer.derived, isCollectionDetail: true)
                .overlay { emptyStateOverlay(derived: organizer.derived, isCollectionDetail: true) }
        }
        .modifier(LocalFavoriteBrowseSearch(
            organizer: organizer,
            isActive: keyboardCommandsEnabled && organizer.selectedMergedGroupCleanBookName != nil
        ))
        .navigationTitle(
            selection.isSelectionMode
                ? L10n.string("favorites.selected_count", selection.selectedEntryCount)
                : (organizer.selectedMergedGroupCleanBookName ?? "")
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

    // MARK: - Content

    private var keyboardCommandsEnabled: Bool {
        !isBookPresented && routes.sheet == nil && routes.dialog == nil && routes.detail == nil
            && !routes.isUpdatesPagePushed && !routes.isBoardFavoritesPushed && !routes.isSyncProgressPushed
            && navigator.path.isEmpty && organizer.removeRemotePrompt == nil
            && !favoriteShare.isFileImporterPresented && !favoriteShare.isFileExporterPresented
            && combinedErrorMessage == nil
    }

    /// Every page of this screen — the root and both pushed detail pages —
    /// draws the user's favorites background, so the pairing of settings and
    /// image data lives here instead of being repeated per call site.
    private func backgrounded(@ViewBuilder _ content: () -> some View) -> some View {
        LocalFavoritesBackground(
            settings: organizer.backgroundSettings,
            imageData: organizer.backgroundImageData,
            content: content
        )
    }

    /// `derived` and `isCollectionDetail` are passed explicitly by the two
    /// call sites (root vs. pushed collection detail) rather than read
    /// ambiently from `organizer`, since both can be mounted at once during
    /// an interactive edge-swipe pop. See `FavoriteLibraryOrganizer.rootDerived`.
    @ViewBuilder
    private func content(derived: LocalFavoriteDerivedState, isCollectionDetail: Bool) -> some View {
        switch organizer.display.layoutMode {
        case .rowCard:
            LocalFavoriteListContent(
                organizer: organizer,
                selection: selection,
                routes: routes,
                showsCover: true,
                derived: derived,
                isCollectionDetail: isCollectionDetail,
                onOpen: onOpen
            )
        case .rowCardText:
            LocalFavoriteListContent(
                organizer: organizer,
                selection: selection,
                routes: routes,
                showsCover: false,
                derived: derived,
                isCollectionDetail: isCollectionDetail,
                onOpen: onOpen
            )
        case .fixedGrid:
            LocalFavoriteGridContent(
                organizer: organizer,
                selection: selection,
                routes: routes,
                isStaggered: false,
                derived: derived,
                isCollectionDetail: isCollectionDetail,
                onOpen: onOpen
            )
        case .staggered:
            LocalFavoriteGridContent(
                organizer: organizer,
                selection: selection,
                routes: routes,
                isStaggered: true,
                derived: derived,
                isCollectionDetail: isCollectionDetail,
                onOpen: onOpen
            )
        }
    }

    // MARK: - Status cards

    private var showsTopStatusCards: Bool {
        guard let snapshot = remoteSync.snapshot else { return false }
        return !snapshot.isHiddenFromFavoritePage
    }

    private var unreadUpdateCount: Int {
        updateMonitor.events.filter { $0.readAt == nil && isEventInFilterScope($0) }.count
    }

    /// Whether `event` still falls within the currently-enabled fid/category
    /// filters. The bell badge and the updates page's event list must agree
    /// with what a fresh check run would actually surface — otherwise
    /// disabling a forum's filter leaves its stale events still counted and
    /// listed as if nothing changed.
    private func isEventInFilterScope(_ event: FavoriteUpdateEvent) -> Bool {
        let fidFilters = updateMonitor.fidFilters
        let categoryFilters = updateMonitor.categoryFilters
        let disabledFidsExist = fidFilters.contains { !$0.enabled }
        let disabledCategoriesExist = categoryFilters.contains { !$0.enabled }
        guard disabledFidsExist || disabledCategoriesExist else { return true }

        let fidMatches: Bool
        if disabledFidsExist, let fid = event.fid {
            fidMatches = fidFilters.first { $0.fid == fid }?.enabled ?? true
        } else {
            fidMatches = true
        }

        let categoryMatches: Bool
        if disabledCategoriesExist {
            // `.favorite` reads live category membership off the favorite
            // itself (never stale); `.mangaDirectory` has no single favorite
            // to read, so it reads the tracked target's own `categoryIDs` —
            // the authoritative per-directory field the check run already
            // maintains, not a proxy inferred from unrelated state.
            let itemCategoryIDs: Set<String>
            switch event.target {
            case .favorite:
                itemCategoryIDs = Set(
                    organizer.favoriteItems.first(where: { $0.target.id == event.target.id })?
                        .locations.compactMap(\.categoryID) ?? []
                )
            case .mangaDirectory:
                itemCategoryIDs = updateMonitor.trackedTargets.first(where: { $0.target == event.target })?.categoryIDs ?? []
            }
            let enabledCategoryIDs = Set(categoryFilters.filter(\.enabled).map(\.categoryID))
            categoryMatches = itemCategoryIDs.isEmpty || !itemCategoryIDs.isDisjoint(with: enabledCategoryIDs)
        } else {
            categoryMatches = true
        }

        return fidMatches && categoryMatches
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

    // MARK: - Toolbar

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

    /// Slim overflow menu: board favorites, organization management,
    /// selection, and the Yamibo sync entry (a running sync opens its
    /// progress directly). The update-check entries stay here until the
    /// dedicated updates page (bell entry) lands.
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

    // MARK: - Dialogs

    private var dialogBinding: Binding<Bool> {
        .presentation(
            isPresented: { routes.dialog != nil },
            clearOnDismiss: { routes.dialog = nil }
        )
    }

    /// Dismissing without picking aborts the pending delete entirely — the
    /// prompt IS the delete's remote-decision step, not an optional add-on.
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
        case .deleteSelection:
            Button(L10n.string("common.cancel"), role: .cancel) {}
            if organizer.selectedFavoritesCanRemoveCurrentLocation {
                Button(L10n.string("favorites.delete_scope.current_location"), role: .destructive) {
                    Task { await organizer.requestDeleteSelection(scope: .currentLocation) }
                }
            }
            Button(L10n.string("favorites.delete_scope.everywhere"), role: .destructive) {
                Task { await organizer.requestDeleteSelection(scope: .everywhere) }
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
                Text(L10n.string("favorites.delete_favorite_scope_message", item.resolvedDisplayTitle))
            } else {
                Text(L10n.string("favorites.delete_favorite_message", item.resolvedDisplayTitle))
            }
        case .deleteSelection:
            Text(deleteSelectionMessage)
        case .dissolveSelectedCollections:
            Text(L10n.string("favorites.bulk_dissolve_collections_message"))
        }
    }

    private var deleteSelectionMessage: String {
        if selection.selectedCollectionCount > 0 {
            return L10n.string("favorites.bulk_delete_mixed_message")
        }
        if organizer.selectedFavoritesCanRemoveCurrentLocation {
            return L10n.string("favorites.bulk_delete_scope_message")
        }
        return L10n.string("favorites.bulk_delete_favorites_message")
    }

    // MARK: - Errors

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
            clearOnDismiss: { clearErrorMessages() }
        )
    }

    @ViewBuilder
    private func emptyStateOverlay(derived: LocalFavoriteDerivedState, isCollectionDetail: Bool) -> some View {
        if derived.cards.isEmpty, isCollectionDetail || derived.visibleCollections.isEmpty {
            if hasSubmittedSearch {
                ContentUnavailableView(L10n.string("favorites.empty.no_results"), systemImage: "magnifyingglass")
            } else if isCollectionDetail {
                ContentUnavailableView(L10n.string("favorites.empty.collection"), systemImage: "folder")
            } else {
                ContentUnavailableView {
                    Label(L10n.string("favorites.empty.favorites"), systemImage: "books.vertical")
                } description: {
                    Text(L10n.string("favorites.empty.sync_hint"))
                }
            }
        }
    }

    private var hasSubmittedSearch: Bool {
        !organizer.filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || organizer.filter.hasActiveFilters
    }
}

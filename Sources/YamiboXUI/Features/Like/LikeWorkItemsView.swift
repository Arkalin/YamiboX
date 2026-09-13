import SwiftUI
import YamiboXCore
import UIKit

/// Second-level Like list for one work: Mine push destination and both
/// readers' `.sheet` share this exact type (see implementation-design.md §9).
///
/// Mine opens a text detail sheet or image browser first; the reader's
/// annotation panel opts into opening the saved anchor directly.
struct LikeWorkItemsView: View {
    let work: LikeWorkKey
    let workTitle: String
    let like: LikeDependencies
    let onOpenAnchor: (LikeAnchorPayload) -> Void
    let onDismiss: (() -> Void)?
    let annotationSelectionRequest: Int?
    let onAnnotationNavigationStateChange: ((ReaderAnnotationSegmentNavigationState) -> Void)?
    let isAnnotationSegmentActive: Bool
    let opensAnchorsDirectly: Bool

    @State private var items: [LikeItem] = []
    @State private var hasLoaded = false
    @State private var chapterInfoByItemID: [String: String] = [:]
    @State private var searchText = ""
    @State private var filter = LikeContentFilter.all
    @State private var loadGeneration = 0
    @State private var presentedTextItem: LikeItem?
    @State private var presentedImageItem: LikeItem?
    @State private var noteEditTarget: LikeItem?

    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isShowingDeleteConfirmation = false

    @Namespace private var imageBrowserZoomNamespace

    init(
        work: LikeWorkKey,
        workTitle: String,
        like: LikeDependencies,
        onOpenAnchor: @escaping (LikeAnchorPayload) -> Void,
        onDismiss: (() -> Void)?,
        annotationSelectionRequest: Int? = nil,
        onAnnotationNavigationStateChange: ((ReaderAnnotationSegmentNavigationState) -> Void)? = nil,
        isAnnotationSegmentActive: Bool = true,
        opensAnchorsDirectly: Bool = false
    ) {
        self.work = work
        self.workTitle = workTitle
        self.like = like
        self.onOpenAnchor = onOpenAnchor
        self.onDismiss = onDismiss
        self.annotationSelectionRequest = annotationSelectionRequest
        self.onAnnotationNavigationStateChange = onAnnotationNavigationStateChange
        self.isAnnotationSegmentActive = isAnnotationSegmentActive
        self.opensAnchorsDirectly = opensAnchorsDirectly
    }

    var body: some View {
        List {
            ForEach(filteredItems) { item in
                LikeItemCard(
                    item: item,
                    chapterInfo: chapterInfoByItemID[item.id],
                    likeImageStore: like.likeImageStore,
                    isSelecting: isSelecting,
                    isSelected: selectedItemIDs.contains(item.id),
                    action: { open(item) },
                    onToggleSelection: { toggleSelection(item.id) }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .deleteSwipeAction(allowsFullSwipe: false, isVisible: !isSelecting) {
                    delete(item)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.imageBrowserZoomNamespace, imageBrowserZoomNamespace)
        .contentMargins(.top, 4, for: .scrollContent)
        // The List stays permanently mounted (rather than being swapped for
        // an empty-state view via if/else) so `.searchable` below always has
        // a stable scrollable view to attach its search bar to — swapping it
        // in right after this view is pushed (before `load()` finishes) is
        // what caused the search bar to briefly ghost/overlap the first row.
        .overlay {
            if !hasLoaded {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView(L10n.string("likes.empty_state"), systemImage: "heart")
            } else if filteredItems.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label { Text(filter.emptyTitle) } icon: { Image(systemName: "heart") }
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if work.kind == .novel {
                LikeContentFilterBar(selection: $filter, usesMenu: onAnnotationNavigationStateChange != nil)
            }
        }
        .likeWorkItemsNavigationTitle(
            isManagedByAnnotationPanel: onAnnotationNavigationStateChange != nil,
            isSelecting: isSelecting,
            selectedItemCount: selectedItemIDs.count,
            workTitle: workTitle
        )
        .likeWorkItemsSearchable(
            isEnabled: isAnnotationSegmentActive,
            text: $searchText,
            prompt: L10n.string("likes.search_placeholder")
        )
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    SelectAllToolbarButton(
                        isSelectionComplete: isAllVisibleSelected,
                        isDisabled: filteredItems.isEmpty,
                        toggle: toggleSelectAll
                    )
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.string("common.done")) {
                        setSelecting(false)
                    }
                    .fontWeight(.semibold)
                }
                if usesSystemSelectionBottomToolbar {
                    ToolbarItem(placement: .bottomBar) {
                        SelectionBottomToolbar(
                            actions: LikeSelectionActions.delete(selectedCount: selectedItemIDs.count) {
                                isShowingDeleteConfirmation = true
                            }
                        )
                    }
                }
            } else if onAnnotationNavigationStateChange == nil {
                if let onDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("common.close"), action: onDismiss)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !filteredItems.isEmpty {
                        Button {
                            setSelecting(true)
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .accessibilityLabel(L10n.string("common.select"))
                    }
                }
            }
        }
        .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting && !usesSystemSelectionBottomToolbar {
                SelectionBottomToolbar(
                    actions: LikeSelectionActions.delete(selectedCount: selectedItemIDs.count) {
                        isShowingDeleteConfirmation = true
                    }
                )
                .selectionBottomToolbarCapsule()
            }
        }
        .destructiveConfirmationDialog(
            L10n.string("likes.delete_selected_items_title"),
            isPresented: $isShowingDeleteConfirmation,
            message: L10n.string("likes.delete_selected_items_message", selectedItemIDs.count)
        ) {
            Task { await deleteSelection() }
        }
        .sensoryFeedback(.selection, trigger: selectedItemIDs)
        .task {
            publishAnnotationNavigationState()
            await load()
        }
        // Appearance-scoped `.task` replacing the removed `.onReceive`
        // bridge: sheets/covers presented from this view don't cancel it, so
        // deletions made in them still refresh live, and anything missed
        // while genuinely covered is caught by the sibling
        // `.task { await load() }` re-running on reappear.
        .task {
            for await changeID in like.likeStore.changes() {
                // Per-instance stream: the guard is kept as the explicit
                // "only this exact store instance" contract.
                guard changeID == like.likeStore.changeID else {
                    continue
                }
                await load()
            }
        }
        .onChange(of: annotationSelectionRequest) { _, request in
            guard request != nil, !filteredItems.isEmpty else { return }
            setSelecting(true)
        }
        .onChange(of: filter) { _, _ in clearSelection() }
        .onChange(of: searchText) { _, _ in clearSelection() }
        .onChange(of: filteredItems.map(\.id)) { _, visibleIDs in
            selectedItemIDs.formIntersection(visibleIDs)
            publishAnnotationNavigationState()
        }
        .sheet(item: $presentedTextItem) { item in
            LikeTextDetailView(
                item: item,
                chapterInfo: chapterInfoByItemID[item.id],
                onSaveNote: { note in
                    Task {
                        _ = try? await like.likeStore.updateNote(id: item.id, note: note)
                    }
                },
                onJumpToOriginal: {
                    presentedTextItem = nil
                    onOpenAnchor(item.anchor)
                }
            )
        }
        .sheet(item: $noteEditTarget) { item in
            LikeNoteEditorSheet(item: item) { note in
                saveImageNote(note, for: item)
            }
        }
        .fullScreenCover(item: $presentedImageItem) { item in
            if let browserItem = imageBrowserItem(for: item) {
                ImageBrowserView(
                    items: [browserItem],
                    initialItemID: item.id,
                    mode: .single,
                    presentation: .zoom(imageBrowserZoomNamespace),
                    onEditNote: { browserItem in
                        noteEditTarget = items.first { $0.id == browserItem.id } ?? item
                    },
                    onJumpToOriginal: {
                        presentedImageItem = nil
                        onOpenAnchor(item.anchor)
                    },
                    onDismiss: { presentedImageItem = nil }
                )
            }
        }
    }

    private var filteredItems: [LikeItem] {
        filter.applying(to: items, chapterTitles: chapterInfoByItemID, searchText: searchText)
    }

    private func open(_ item: LikeItem) {
        if opensAnchorsDirectly {
            onOpenAnchor(item.anchor)
            return
        }
        switch item.kind {
        case .text:
            presentedTextItem = item
        case .image:
            guard item.sourceImageURL != nil else { return }
            presentedImageItem = item
        }
    }

    private func imageBrowserItem(for item: LikeItem) -> ImageBrowserItem? {
        LikeImageBrowserItemFactory.make(
            item: item,
            title: chapterInfoByItemID[item.id] ?? workTitle,
            likeImageStore: like.likeImageStore
        )
    }

    private func saveImageNote(_ note: String?, for item: LikeItem) {
        let normalizedNote = normalizedNote(note)
        var updatedItem = item
        updatedItem.note = normalizedNote
        items = items.map { $0.id == item.id ? updatedItem : $0 }
        if presentedImageItem?.id == item.id {
            presentedImageItem = updatedItem
        }
        Task {
            _ = try? await like.likeStore.updateNote(id: item.id, note: normalizedNote)
        }
    }

    private func normalizedNote(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let fetched = await like.likeStore.likes(for: work)
        let sorted: [LikeItem]
        let chapterInfo: [String: String]
        switch work.kind {
        case .novel:
            sorted = Self.sortedNovelItems(fetched)
            chapterInfo = await like.resolveChapterInfo(for: sorted, work: work)
        case .manga:
            // Manga Like Items never store a chapter ordinal (see
            // implementation-design.md §11): chapter order is always resolved
            // live against the directory's current chapter array.
            let directory = try? await like.mangaDirectoryStore.directory(named: work.id)
            sorted = Self.sortedMangaItems(fetched, chapterOrder: Self.chapterOrder(for: directory))
            chapterInfo = await like.resolveChapterInfo(for: sorted, work: work, mangaDirectory: directory)
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        items = sorted
        chapterInfoByItemID = chapterInfo
        selectedItemIDs.formIntersection(filteredItems.map(\.id))
        hasLoaded = true
        publishAnnotationNavigationState()
    }

    private func delete(_ item: LikeItem) {
        Task {
            try? await like.likeStore.delete(id: item.id)
            if item.kind == .image {
                try? await like.likeImageStore.delete(id: item.id)
            }
            await load()
        }
    }

    // MARK: - Selection

    private func toggleSelection(_ id: String) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
        publishAnnotationNavigationState()
    }

    private var isAllVisibleSelected: Bool {
        let visibleIDs = Set(filteredItems.map(\.id))
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedItemIDs)
    }

    /// Not a true per-item inversion — mirrors `FavoriteLibraryOrganizer
    /// .toggleSelectAllVisible`/`SystemSettingsViewModel
    /// .toggleAllOfflineCacheManagementRows`: selects every currently visible
    /// (search-filtered) item, or clears the whole selection when everything
    /// visible is already selected.
    private func toggleSelectAll() {
        let visibleIDs = Set(filteredItems.map(\.id))
        guard !visibleIDs.isEmpty else { return }
        if visibleIDs.isSubset(of: selectedItemIDs) {
            selectedItemIDs.subtract(visibleIDs)
        } else {
            selectedItemIDs.formUnion(visibleIDs)
        }
        publishAnnotationNavigationState()
    }

    private func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        if !selecting {
            selectedItemIDs.removeAll()
        }
        publishAnnotationNavigationState()
    }

    private func clearSelection() {
        selectedItemIDs.removeAll()
        publishAnnotationNavigationState()
    }

    private func deleteSelection() async {
        let ids = selectedItemIDs.intersection(filteredItems.map(\.id))
        let imageIDs = items.filter { $0.kind == .image && ids.contains($0.id) }.map(\.id)
        try? await like.likeStore.delete(ids: Array(ids))
        for imageID in imageIDs {
            try? await like.likeImageStore.delete(id: imageID)
        }
        setSelecting(false)
        await load()
    }

    private func publishAnnotationNavigationState() {
        onAnnotationNavigationStateChange?(
            ReaderAnnotationSegmentNavigationState(
                itemCount: filteredItems.count,
                isSelecting: isSelecting,
                selectedItemCount: selectedItemIDs.count
            )
        )
    }

    /// Novel Like Items arrive from the store already in book order: the row
    /// carries a persisted `sortKey` derived from its anchor, which is exact
    /// once a reader session has resolved the chapter's position on its forum
    /// page.
    ///
    /// This used to sort here on `chapterIdentity.rawValue`, a string — so
    /// `"post:9…"` sorted after `"post:10…"` and annotations in a long thread
    /// came out in an order that looked arbitrary.
    private static func sortedNovelItems(_ items: [LikeItem]) -> [LikeItem] {
        items.sorted { lhs, rhs in
            if lhs.sortKey != rhs.sortKey {
                return lhs.sortKey < rhs.sortKey
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    // Mirrors `MangaChapterWindow.chapterOrder()`: first occurrence wins so a
    // directory with a duplicate tid doesn't crash on dictionary insertion.
    private static func chapterOrder(for directory: MangaDirectory?) -> [String: Int] {
        var order: [String: Int] = [:]
        for (index, chapter) in (directory?.chapters ?? []).enumerated() where order[chapter.tid] == nil {
            order[chapter.tid] = index
        }
        return order
    }

    private static func sortedMangaItems(_ items: [LikeItem], chapterOrder: [String: Int]) -> [LikeItem] {
        items.sorted { lhs, rhs in
            guard case let .mangaImage(lhsAnchor) = lhs.anchor,
                  case let .mangaImage(rhsAnchor) = rhs.anchor else {
                return false
            }
            let lhsOrder = chapterOrder[lhsAnchor.chapterTID] ?? Int.max
            let rhsOrder = chapterOrder[rhsAnchor.chapterTID] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhsAnchor.pageLocalIndex < rhsAnchor.pageLocalIndex
        }
    }
}

private extension View {
    @ViewBuilder
    func likeWorkItemsNavigationTitle(
        isManagedByAnnotationPanel: Bool,
        isSelecting: Bool,
        selectedItemCount: Int,
        workTitle: String
    ) -> some View {
        if isManagedByAnnotationPanel {
            self
        } else {
            self
                .navigationTitle(
                    isSelecting
                        ? L10n.string("likes.selected_count", selectedItemCount)
                        : workTitle
                )
                .yamiboInlineNavigationTitleDisplayMode()
                .navigationBarBackButtonHidden(isSelecting)
        }
    }

    @ViewBuilder
    func likeWorkItemsSearchable(
        isEnabled: Bool,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        if isEnabled {
            self.searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}

enum LikeImageBrowserItemFactory {
    static func make(
        item: LikeItem,
        title: String,
        likeImageStore: LikeImageStore
    ) -> ImageBrowserItem? {
        guard let url = item.sourceImageURL else { return nil }
        let itemID = item.id
        return ImageBrowserItem(
            id: itemID,
            source: YamiboImageSource(url: url),
            title: title,
            caption: item.hasNote ? item.note : nil,
            localDataProvider: { await likeImageStore.loadData(id: itemID) }
        )
    }
}

/// One liked-item card: a quote-style card for text excerpts, a full-width
/// photo card for images. Tapping either opens a detail surface instead of
/// jumping straight to the original position (see `LikeWorkItemsView.open`).
private struct LikeItemCard: View {
    let item: LikeItem
    let chapterInfo: String?
    let likeImageStore: LikeImageStore
    let isSelecting: Bool
    let isSelected: Bool
    let action: () -> Void
    let onToggleSelection: () -> Void

    @Environment(\.imageBrowserZoomNamespace) private var imageBrowserZoomNamespace

    var body: some View {
        Button {
            if isSelecting {
                onToggleSelection()
            } else {
                action()
            }
        } label: {
            switch item.kind {
            case .text:
                LikeTextCardContent(item: item, chapterInfo: chapterInfo)
            case .image:
                LikeImageCardContent(
                    itemID: item.id,
                    sourceImageURL: item.sourceImageURL,
                    note: item.hasNote ? item.note : nil,
                    chapterInfo: chapterInfo,
                    createdAt: item.createdAt,
                    likeImageStore: likeImageStore
                )
            }
        }
        .buttonStyle(.plain)
        .imageBrowserZoomSource(id: item.id, in: item.kind == .image ? imageBrowserZoomNamespace : nil)
        .accessibilityIdentifier("like.item.\(item.id)")
        .favoriteSelectionEmphasis(
            isSelectionMode: isSelecting,
            isSelected: isSelected,
            cornerRadius: 8,
            // These rows are flat, so the border has nothing but glyphs to sit
            // against without this. The list row gives the same amount back.
            contentInset: 8
        )
    }
}

private struct LikeTextCardContent: View {
    let item: LikeItem
    let chapterInfo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LikeStyleAppearance.inlineExcerptLine(for: item))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("like.excerpt")
            if item.hasNote, let note = item.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 4)
            }
            LikeItemMetadata(chapterTitle: chapterInfo, createdAt: item.createdAt)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct LikeImageCardContent: View {
    let itemID: String
    let sourceImageURL: URL?
    let note: String?
    let chapterInfo: String?
    let createdAt: Date
    let likeImageStore: LikeImageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 220)
                .overlay {
                    LikeImageCardPhoto(
                        itemID: itemID,
                        sourceImageURL: sourceImageURL,
                        likeImageStore: likeImageStore
                    )
                }
                .clipped()

            LikeImageCardDetails(
                note: note,
                chapterInfo: chapterInfo,
                createdAt: createdAt
            )
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct LikeImageCardDetails: View {
    let note: String?
    let chapterInfo: String?
    let createdAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            LikeItemMetadata(chapterTitle: chapterInfo, createdAt: createdAt)
        }
        .padding(12)
    }
}

private struct LikeImageCardPhoto: View {
    let itemID: String
    let sourceImageURL: URL?
    let likeImageStore: LikeImageStore

    @State private var localData: Data?
    @State private var didFinishLocalLookup = false

    var body: some View {
        Group {
            if let localData, let uiImage = UIImage(data: localData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if didFinishLocalLookup {
                YamiboRemoteImage(source: sourceImageURL.map { YamiboImageSource(url: $0) }) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.12)
                } failure: {
                    ZStack {
                        Color.secondary.opacity(0.08)
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Color.secondary.opacity(0.12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            localData = await likeImageStore.loadData(id: itemID)
            didFinishLocalLookup = true
        }
    }
}

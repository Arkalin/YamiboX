import SwiftUI
import YamiboXCore
import UIKit

/// Second-level Like list for one work: Mine push destination and both
/// readers' `.sheet` share this exact type (see implementation-design.md §9).
///
/// Tapping a card never jumps straight to the original reading position —
/// it opens a text detail sheet or the image browser, and jumping back is a
/// menu action inside those, so browsing likes never yanks the reader out
/// from under the user by accident.
struct LikeWorkItemsView: View {
    let work: LikeWorkKey
    let workTitle: String
    let like: LikeDependencies
    let onOpenAnchor: (LikeAnchorPayload) -> Void
    let onDismiss: (() -> Void)?

    @State private var items: [LikeItem] = []
    @State private var chapterInfoByItemID: [String: String] = [:]
    @State private var searchText = ""
    @State private var presentedTextItem: LikeItem?
    @State private var presentedImageItem: LikeItem?

    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isShowingDeleteConfirmation = false

    @Namespace private var imageBrowserZoomNamespace

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
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .deleteSwipeAction(allowsFullSwipe: false, isVisible: !isSelecting) {
                    delete(item)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.imageBrowserZoomNamespace, imageBrowserZoomNamespace)
        .contentMargins(.top, 8, for: .scrollContent)
        // The List stays permanently mounted (rather than being swapped for
        // an empty-state view via if/else) so `.searchable` below always has
        // a stable scrollable view to attach its search bar to — swapping it
        // in right after this view is pushed (before `load()` finishes) is
        // what caused the search bar to briefly ghost/overlap the first row.
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(L10n.string("likes.empty_state"), systemImage: "heart")
            } else if filteredItems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle(
            isSelecting
                ? L10n.string("likes.selected_count", selectedItemIDs.count)
                : workTitle
        )
        // Inline in the reader's annotation panel so this segment's header
        // matches the bookmark segment's — the two swap in place under one
        // picker, and a large title on only one of them makes the picker jump.
        // Pushed from Mine there is no sibling to match, so the large title
        // stays. `onDismiss` is the same signal the 关闭 button keys off: it is
        // set only by the sheet presentation.
        .navigationBarTitleDisplayMode(onDismiss == nil ? .automatic : .inline)
        .navigationBarBackButtonHidden(isSelecting)
        .searchable(text: $searchText, prompt: L10n.string("likes.search_placeholder"))
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
            } else {
                if let onDismiss {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("common.close"), action: onDismiss)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !items.isEmpty {
                        Button(L10n.string("common.select")) {
                            setSelecting(true)
                        }
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
        .task { await load() }
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
                Task { await load() }
            }
        }
        .sheet(item: $presentedTextItem) { item in
            LikeTextDetailView(
                item: item,
                chapterInfo: chapterInfoByItemID[item.id],
                onJumpToOriginal: {
                    presentedTextItem = nil
                    onOpenAnchor(item.anchor)
                }
            )
        }
        .fullScreenCover(item: $presentedImageItem) { item in
            if let browserItem = imageBrowserItem(for: item) {
                ImageBrowserView(
                    items: [browserItem],
                    initialItemID: item.id,
                    mode: .single,
                    presentation: .zoom(imageBrowserZoomNamespace),
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
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            if let excerpt = item.excerptText, excerpt.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            if let chapterInfo = chapterInfoByItemID[item.id], chapterInfo.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            return false
        }
    }

    private func open(_ item: LikeItem) {
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

    private func load() async {
        let fetched = await like.likeStore.likes(for: work)
        switch work.kind {
        case .novel:
            let sorted = Self.sortedNovelItems(fetched)
            items = sorted
            chapterInfoByItemID = await LikeChapterInfoResolver.novelChapterInfo(
                for: sorted,
                threadID: work.id,
                cacheStore: like.novelReaderCacheStore
            )
        case .manga:
            // Manga Like Items never store a chapter ordinal (see
            // implementation-design.md §11): chapter order is always resolved
            // live against the directory's current chapter array.
            let directory = try? await like.mangaDirectoryStore.directory(named: work.id)
            let sorted = Self.sortedMangaItems(fetched, chapterOrder: Self.chapterOrder(for: directory))
            items = sorted
            chapterInfoByItemID = LikeChapterInfoResolver.mangaChapterInfo(for: sorted, directory: directory)
        }
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
    }

    private func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        if !selecting {
            selectedItemIDs.removeAll()
        }
    }

    private func deleteSelection() async {
        let ids = selectedItemIDs
        let imageIDs = items.filter { $0.kind == .image && ids.contains($0.id) }.map(\.id)
        try? await like.likeStore.delete(ids: Array(ids))
        for imageID in imageIDs {
            try? await like.likeImageStore.delete(id: imageID)
        }
        setSelecting(false)
        await load()
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
        .favoriteSelectionEmphasis(
            isSelectionMode: isSelecting,
            isSelected: isSelected,
            cornerRadius: 10,
            // These rows are flat, so the border has nothing but glyphs to sit
            // against without this. The list row gives the same amount back.
            contentInset: 8
        )
    }
}

private struct LikeTextCardContent: View {
    let item: LikeItem
    let chapterInfo: String?

    /// Apple Books-style highlight row: one line of excerpt with the mark
    /// painted inline (clause context plain around it), then — after a blank
    /// gap — the note, then the date. The style needs no separate indicator
    /// because the line itself is painted in it.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let chapterInfo {
                Text(chapterInfo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(LikeStyleAppearance.inlineExcerptLine(for: item))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if item.hasNote, let note = item.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // The "blank line" between excerpt and note: enough gap to
                    // read as a paragraph break, not merely line spacing.
                    .padding(.top, 12)
            }
            Text(LocalFavoriteRelativeDate.string(from: item.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
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
            LikeImageCardPhoto(
                itemID: itemID,
                sourceImageURL: sourceImageURL,
                likeImageStore: likeImageStore
            )
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()

            LikeImageCardDetails(
                note: note,
                chapterInfo: chapterInfo,
                createdAt: createdAt
            )
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

            HStack(spacing: 6) {
                if let chapterInfo {
                    Text(chapterInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(LocalFavoriteRelativeDate.string(from: createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

import SwiftUI
import YamiboXCore

/// The shared reader-library panel, with an optional chapters tab followed by
/// the persisted bookmarks and likes tabs.
struct ReaderAnnotationPanel<ChapterContent: View>: View {
    let work: LikeWorkKey
    let workTitle: String
    let like: LikeDependencies
    @Binding private var annotationSegment: ReaderAnnotationSegment
    let onOpenBookmark: (BookmarkItem) -> Void
    let onOpenLikeAnchor: (LikeAnchorPayload) -> Void
    let onDismiss: () -> Void
    private let tabs: [ReaderLibraryPanelTab]
    private let chapterContent: (Bool, @escaping (ReaderAnnotationSegmentNavigationState) -> Void) -> ChapterContent

    @State private var selectedTab: ReaderLibraryPanelTab
    @State private var chapterNavigationState = ReaderAnnotationSegmentNavigationState()
    @State private var bookmarkNavigationState = ReaderAnnotationSegmentNavigationState()
    @State private var likeNavigationState = ReaderAnnotationSegmentNavigationState()
    @State private var bookmarkSelectionRequest = 0
    @State private var likeSelectionRequest = 0

    init(
        work: LikeWorkKey,
        workTitle: String,
        like: LikeDependencies,
        annotationSegment: Binding<ReaderAnnotationSegment>,
        initialTab: ReaderLibraryPanelTab,
        onOpenBookmark: @escaping (BookmarkItem) -> Void,
        onOpenLikeAnchor: @escaping (LikeAnchorPayload) -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder chapterContent: @escaping (
            Bool,
            @escaping (ReaderAnnotationSegmentNavigationState) -> Void
        ) -> ChapterContent
    ) {
        self.work = work
        self.workTitle = workTitle
        self.like = like
        self._annotationSegment = annotationSegment
        self.onOpenBookmark = onOpenBookmark
        self.onOpenLikeAnchor = onOpenLikeAnchor
        self.onDismiss = onDismiss
        self.tabs = ReaderLibraryPanelTab.available(includingChapters: true)
        self.chapterContent = chapterContent
        self._selectedTab = State(initialValue: initialTab)
    }

    private var activeNavigationState: ReaderAnnotationSegmentNavigationState {
        switch selectedTab {
        case .chapters: chapterNavigationState
        case .bookmarks: bookmarkNavigationState
        case .likes: likeNavigationState
        }
    }

    private var tabBinding: Binding<ReaderLibraryPanelTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                selectedTab = newValue
                if let segment = newValue.annotationSegment {
                    annotationSegment = segment
                }
            }
        )
    }

    private var navigationTitle: String {
        guard activeNavigationState.isSelecting else { return workTitle }
        return activeNavigationState.selectionTitle
            ?? L10n.string("likes.selected_count", activeNavigationState.selectedItemCount)
    }

    private var isAnnotationTabSelected: Bool {
        selectedTab.annotationSegment != nil
    }

    private func requestAnnotationSelection() {
        switch selectedTab {
        case .chapters:
            break
        case .bookmarks:
            bookmarkSelectionRequest += 1
        case .likes:
            likeSelectionRequest += 1
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: tabBinding) {
                ForEach(tabs, id: \.self) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(activeNavigationState.isSelecting)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Keep every tab mounted while the picker changes. Besides
            // preserving scroll position, it prevents a freshly-created list
            // from briefly presenting its empty state before its store load
            // finishes.
            ZStack {
                chapterContent(selectedTab == .chapters) { chapterNavigationState = $0 }
                    .opacity(selectedTab == .chapters ? 1 : 0)
                    .allowsHitTesting(selectedTab == .chapters)
                    .accessibilityHidden(selectedTab != .chapters)

                ReaderBookmarkListView(
                    work: work,
                    bookmarkStore: like.bookmarkStore,
                    onOpen: { item in
                        onDismiss()
                        onOpenBookmark(item)
                    },
                    selectionRequest: bookmarkSelectionRequest,
                    onNavigationStateChange: { bookmarkNavigationState = $0 }
                )
                .opacity(selectedTab == .bookmarks ? 1 : 0)
                .allowsHitTesting(selectedTab == .bookmarks)
                .accessibilityHidden(selectedTab != .bookmarks)

                LikeWorkItemsView(
                    work: work,
                    workTitle: workTitle,
                    like: like,
                    onOpenAnchor: onOpenLikeAnchor,
                    onDismiss: onDismiss,
                    annotationSelectionRequest: likeSelectionRequest,
                    onAnnotationNavigationStateChange: { likeNavigationState = $0 },
                    isAnnotationSegmentActive: selectedTab == .likes
                )
                .opacity(selectedTab == .likes ? 1 : 0)
                .allowsHitTesting(selectedTab == .likes)
                .accessibilityHidden(selectedTab != .likes)
            }
        }
        // The navigation item belongs to the panel, not its replaceable
        // segment bodies. Replacing a List otherwise briefly removes and
        // re-adds the title and Select item, which produces a clipped frame.
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(activeNavigationState.isSelecting)
        .toolbar {
            if !activeNavigationState.isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.string("common.close"))
                }
                ToolbarItem(placement: .primaryAction) {
                    if isAnnotationTabSelected, activeNavigationState.itemCount > 0 {
                        Button {
                            requestAnnotationSelection()
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .accessibilityLabel(L10n.string("common.select"))
                    }
                }
            }
        }
    }
}

extension ReaderAnnotationPanel where ChapterContent == EmptyView {
    init(
        work: LikeWorkKey,
        workTitle: String,
        like: LikeDependencies,
        annotationSegment: Binding<ReaderAnnotationSegment>,
        onOpenBookmark: @escaping (BookmarkItem) -> Void,
        onOpenLikeAnchor: @escaping (LikeAnchorPayload) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.work = work
        self.workTitle = workTitle
        self.like = like
        self._annotationSegment = annotationSegment
        self.onOpenBookmark = onOpenBookmark
        self.onOpenLikeAnchor = onOpenLikeAnchor
        self.onDismiss = onDismiss
        self.tabs = ReaderLibraryPanelTab.available(includingChapters: false)
        self.chapterContent = { _, _ in EmptyView() }
        self._selectedTab = State(
            initialValue: ReaderLibraryPanelTab(annotationSegment: annotationSegment.wrappedValue)
        )
    }
}

/// State each segment reports to the panel-owned navigation item.
///
/// Keeping this compact value at the panel boundary prevents a segment swap
/// from temporarily owning an incomplete navigation bar during layout.
struct ReaderAnnotationSegmentNavigationState: Equatable {
    var itemCount = 0
    var isSelecting = false
    var selectedItemCount = 0
    var selectionTitle: String?
}

/// The bookmark segment: book-ordered rows, tap to jump, swipe to delete.
///
/// Rows read from the persisted snapshot only — never from a live projection —
/// so a bookmark synced from another device renders correctly on a device that
/// has never opened that chapter.
struct ReaderBookmarkListView: View {
    let work: LikeWorkKey
    let bookmarkStore: BookmarkStore
    let onOpen: (BookmarkItem) -> Void
    let selectionRequest: Int
    let onNavigationStateChange: (ReaderAnnotationSegmentNavigationState) -> Void

    @State private var items: [BookmarkItem] = []
    @State private var hasLoaded = false
    @State private var isSelecting = false
    @State private var selectedItemIDs: Set<String> = []
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        List {
            ForEach(items) { item in
                Button {
                    if isSelecting {
                        toggleSelection(item.id)
                    } else {
                        onOpen(item)
                    }
                } label: {
                    ReaderBookmarkRow(item: item)
                }
                .buttonStyle(.plain)
                .favoriteSelectionEmphasis(
                    isSelectionMode: isSelecting,
                    isSelected: selectedItemIDs.contains(item.id),
                    cornerRadius: 10,
                    // Matches the like segment: flat rows need the border held
                    // off the text, and the list row gives the space back.
                    contentInset: 8
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
        .contentMargins(.top, 8, for: .scrollContent)
        .overlay {
            if !hasLoaded {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("annotations.bookmark.empty_state"), systemImage: "bookmark")
                } description: {
                    Text(L10n.string("annotations.bookmark.empty_state_hint"))
                }
            }
        }
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    SelectAllToolbarButton(
                        isSelectionComplete: isAllSelected,
                        isDisabled: items.isEmpty,
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
                        SelectionBottomToolbar(actions: deleteActions)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting && !usesSystemSelectionBottomToolbar {
                SelectionBottomToolbar(actions: deleteActions)
                    .selectionBottomToolbarCapsule()
            }
        }
        .destructiveConfirmationDialog(
            L10n.string("annotations.bookmark.delete_selected_title"),
            isPresented: $isShowingDeleteConfirmation,
            message: L10n.string("annotations.bookmark.delete_selected_message", selectedItemIDs.count)
        ) {
            Task { await deleteSelection() }
        }
        .sensoryFeedback(.selection, trigger: selectedItemIDs)
        .task {
            publishNavigationState()
            await load()
        }
        .task {
            // Same appearance-scoped observation pattern the reader uses for
            // the Like store: one stream, torn down with the view.
            for await _ in bookmarkStore.changes() {
                await load()
            }
        }
        .onChange(of: selectionRequest) { _, _ in
            guard !items.isEmpty else { return }
            setSelecting(true)
        }
    }

    private var deleteActions: [SelectionToolbarAction] {
        LikeSelectionActions.delete(selectedCount: selectedItemIDs.count) {
            isShowingDeleteConfirmation = true
        }
    }

    private var isAllSelected: Bool {
        !items.isEmpty && selectedItemIDs.count == items.count
    }

    private func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        // Never carry a selection out of selection mode: the next entry would
        // start with rows already ticked that the user cannot see.
        selectedItemIDs.removeAll()
        publishNavigationState()
    }

    private func toggleSelection(_ id: String) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
        publishNavigationState()
    }

    private func toggleSelectAll() {
        if isAllSelected {
            selectedItemIDs.removeAll()
        } else {
            selectedItemIDs = Set(items.map(\.id))
        }
        publishNavigationState()
    }

    private func load() async {
        items = await bookmarkStore.bookmarks(for: work)
        // A bookmark deleted on another device disappears mid-selection;
        // dropping the stale ids keeps the count honest.
        selectedItemIDs.formIntersection(Set(items.map(\.id)))
        hasLoaded = true
        publishNavigationState()
    }

    private func delete(_ item: BookmarkItem) {
        Task {
            try? await bookmarkStore.delete(id: item.id)
            await load()
        }
    }

    private func deleteSelection() async {
        for id in selectedItemIDs {
            try? await bookmarkStore.delete(id: id)
        }
        await load()
        setSelecting(false)
    }

    private func publishNavigationState() {
        onNavigationStateChange(
            ReaderAnnotationSegmentNavigationState(
                itemCount: items.count,
                isSelecting: isSelecting,
                selectedItemCount: selectedItemIDs.count
            )
        )
    }
}

private struct ReaderBookmarkRow: View {
    let item: BookmarkItem

    var body: some View {
        let presentation = ReaderBookmarkRowPresentation(
            item: item,
            // Same relative-date wording the Like list already uses, so the
            // two segments of one panel don't phrase time differently.
            relativeDateText: LocalFavoriteRelativeDate.string(from: item.createdAt)
        )

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bookmark.fill")
                .font(.footnote)
                .foregroundStyle(.tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.primaryText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let secondaryText = presentation.secondaryText {
                    Text(secondaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

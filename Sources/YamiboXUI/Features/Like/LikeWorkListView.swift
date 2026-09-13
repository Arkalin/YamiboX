import SwiftUI
import YamiboXCore

/// First-level Like list: one row per liked work.
struct LikeWorkListView: View {
    let likeDependencies: LikeDependencies
    let contentCoverStore: ContentCoverStore
    let favoriteLibraryStore: FavoriteLibraryStore
    let settingsStore: SettingsStore
    let appModel: YamiboAppModel
    var onClose: (() -> Void)? = nil
    var categorySelection: Binding<LikeWorkFilter>? = nil
    var onSelectionModeChange: (Bool) -> Void = { _ in }

    @State private var summaries: [LikeWorkSummary] = []
    @State private var titlesByWorkKey: [LikeWorkKey: String] = [:]
    @State private var coverURLsByWorkKey: [LikeWorkKey: URL] = [:]
    @State private var searchText = ""
    @State private var localFilter = LikeWorkFilter.all
    @State private var hasLoaded = false
    @State private var loadGeneration = 0
    @State private var pushedWorkKey: LikeWorkKey?

    @State private var isSelecting = false
    @State private var selectedWorkKeys: Set<LikeWorkKey> = []
    @State private var isShowingDeleteConfirmation = false

    private var filteredSummaries: [LikeWorkSummary] {
        filter.applying(to: summaries, titles: titlesByWorkKey, searchText: searchText)
    }

    private var filter: LikeWorkFilter {
        filterBinding.wrappedValue
    }

    private var filterBinding: Binding<LikeWorkFilter> {
        categorySelection ?? $localFilter
    }

    var body: some View {
        LibraryPageNavigation(
            ownsNavigation: categorySelection == nil,
            isCloseEnabled: !isSelecting,
            onClose: onClose
        ) {
            List(filteredSummaries, id: \.workKey) { summary in
                Button {
                    if isSelecting {
                        toggleSelection(summary.workKey)
                    } else {
                        pushedWorkKey = summary.workKey
                    }
                } label: {
                    LikeWorkRow(
                        title: title(for: summary.workKey),
                        coverURL: coverURLsByWorkKey[summary.workKey],
                        kind: summary.workKey.kind,
                        itemCount: summary.itemCount,
                        lastLikedAt: summary.lastLikedAt,
                        isSelecting: isSelecting,
                        isSelected: selectedWorkKeys.contains(summary.workKey)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("like.work.\(summary.workKey.kind.rawValue).\(summary.workKey.id)")
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowSeparator(.visible, edges: .bottom)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            // Kept permanently mounted rather than swapped for an empty-state
            // view — see the matching comment in LikeWorkItemsView.body for why
            // that swap makes `.searchable`'s search bar ghost during a push.
            .overlay {
                if !hasLoaded {
                    ProgressView()
                } else if summaries.isEmpty {
                    ContentUnavailableView(L10n.string("likes.empty_state"), systemImage: "heart")
                } else if filteredSummaries.isEmpty {
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
                LikeWorkFilterBar(selection: filterBinding)
                    .disabled(isSelecting && (categorySelection != nil || UIDevice.current.userInterfaceIdiom == .pad))
            }
            .navigationTitle(
                filter.navigationTitle(
                    usesSidebar: false,
                    selectedCount: isSelecting ? selectedWorkKeys.count : nil
                )
            )
            .navigationBarBackButtonHidden(isSelecting)
            .searchable(
                text: $searchText,
                prompt: L10n.string("likes.search_works_placeholder")
            )
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .cancellationAction) {
                        SelectAllToolbarButton(
                            isSelectionComplete: isAllVisibleSelected,
                            isDisabled: filteredSummaries.isEmpty,
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
                                actions: LikeSelectionActions.delete(selectedCount: selectedWorkKeys.count) {
                                    isShowingDeleteConfirmation = true
                                }
                            )
                        }
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        if !filteredSummaries.isEmpty {
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
            .toolbar(isSelecting && categorySelection == nil ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting && !usesSystemSelectionBottomToolbar {
                    SelectionBottomToolbar(
                        actions: LikeSelectionActions.delete(selectedCount: selectedWorkKeys.count) {
                            isShowingDeleteConfirmation = true
                        }
                    )
                    .selectionBottomToolbarCapsule()
                }
            }
            .navigationDestination(item: $pushedWorkKey) { workKey in
                LikeWorkItemsView(
                    work: workKey,
                    workTitle: title(for: workKey),
                    like: likeDependencies,
                    onOpenAnchor: { anchor in openAnchor(anchor, work: workKey) },
                    onDismiss: nil
                )
            }
        }
        .task { await load() }
        // Appearance-scoped `.task` replacing the removed `.onReceive`
        // bridge: while this list is visible the reaction is identical, and
        // a change landing while it's covered (a pushed LikeWorkItemsView)
        // is picked up by the sibling `.task { await load() }` re-running on
        // reappear, so the state the user sees is unchanged.
        .task {
            for await changeID in likeDependencies.likeStore.changes() {
                // Per-instance stream: the guard is kept as the explicit
                // "only this exact store instance" contract.
                guard changeID == likeDependencies.likeStore.changeID else {
                    continue
                }
                await load()
            }
        }
        .destructiveConfirmationDialog(
            L10n.string("likes.delete_selected_works_title"),
            isPresented: $isShowingDeleteConfirmation,
            message: L10n.string("likes.delete_selected_works_message", selectedWorkKeys.count)
        ) {
            Task { await deleteSelection() }
        }
        .sensoryFeedback(.selection, trigger: selectedWorkKeys)
        .onAppear { onSelectionModeChange(isSelecting) }
        .onChange(of: isSelecting) { _, selecting in
            onSelectionModeChange(selecting)
        }
        .onDisappear {
            onSelectionModeChange(false)
        }
        .onChange(of: filter) { _, _ in
            setSelecting(false)
            isShowingDeleteConfirmation = false
            pushedWorkKey = nil
        }
        .onChange(of: searchText) { _, _ in selectedWorkKeys.removeAll() }
        .onChange(of: filteredSummaries.map(\.workKey)) { _, visibleKeys in
            selectedWorkKeys.formIntersection(visibleKeys)
        }
    }

    private func title(for workKey: LikeWorkKey) -> String {
        titlesByWorkKey[workKey] ?? workKey.id
    }

    // MARK: - Selection

    private func toggleSelection(_ workKey: LikeWorkKey) {
        if selectedWorkKeys.contains(workKey) {
            selectedWorkKeys.remove(workKey)
        } else {
            selectedWorkKeys.insert(workKey)
        }
    }

    private var isAllVisibleSelected: Bool {
        let visibleKeys = Set(filteredSummaries.map(\.workKey))
        return !visibleKeys.isEmpty && visibleKeys.isSubset(of: selectedWorkKeys)
    }

    /// Not a true per-item inversion — mirrors `FavoriteLibraryOrganizer
    /// .toggleSelectAllVisible`/`SystemSettingsViewModel
    /// .toggleAllOfflineCacheManagementRows`: selects every currently visible
    /// (search-filtered) work, or clears the whole selection when everything
    /// visible is already selected.
    private func toggleSelectAll() {
        let visibleKeys = Set(filteredSummaries.map(\.workKey))
        guard !visibleKeys.isEmpty else { return }
        if visibleKeys.isSubset(of: selectedWorkKeys) {
            selectedWorkKeys.subtract(visibleKeys)
        } else {
            selectedWorkKeys.formUnion(visibleKeys)
        }
    }

    private func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        if !selecting {
            selectedWorkKeys.removeAll()
        }
    }

    private func deleteSelection() async {
        let keys = selectedWorkKeys.intersection(filteredSummaries.map(\.workKey))
        for key in keys {
            try? await likeDependencies.likeStore.deleteAll(workKey: key)
        }
        setSelecting(false)
        await load()
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        async let fetchedSummaries = likeDependencies.likeStore.workSummaries()
        async let favoriteDocument = try? favoriteLibraryStore.load()
        let (summaries, document) = await (fetchedSummaries, favoriteDocument ?? FavoriteLibraryDocument())

        var titles: [LikeWorkKey: String] = [:]
        var covers: [LikeWorkKey: URL] = [:]
        for summary in summaries {
            let key = summary.workKey
            switch key.kind {
            case .novel:
                // Like Items don't persist a work title (unlike
                // implementation-design.md §1); best-effort resolve it from a
                // matching favorite, falling back to the raw tid.
                titles[key] = document.items.first(where: { $0.target.threadID == key.id })?.resolvedDisplayTitle
                covers[key] = await contentCoverStore.cover(for: .thread(tid: key.id))?.resolvedURL
            case .manga:
                titles[key] = key.id
                covers[key] = await contentCoverStore.cover(for: .smartManga(cleanBookName: key.id))?.resolvedURL
            }
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        self.summaries = summaries
        titlesByWorkKey = titles
        coverURLsByWorkKey = covers
        hasLoaded = true
    }

    private func openAnchor(_ anchor: LikeAnchorPayload, work: LikeWorkKey) {
        let workTitle = title(for: work)
        switch anchor {
        case let .novelText(textAnchor):
            openNovelReader(
                threadID: work.id,
                workTitle: workTitle,
                resumePoint: NovelResumePoint(
                    view: textAnchor.view,
                    chapterIdentity: textAnchor.chapterIdentity,
                    textSegmentIdentity: textAnchor.startSegmentIdentity,
                    displayedTextOffset: textAnchor.start.offset,
                    chapterOrdinal: 0,
                    segmentProgress: 0,
                    authorID: textAnchor.resolvedAuthorID,
                    readingModeHint: .paged
                )
            )
        case let .novelImage(imageAnchor):
            openNovelReader(
                threadID: work.id,
                workTitle: workTitle,
                resumePoint: NovelResumePoint(
                    view: imageAnchor.view,
                    chapterIdentity: imageAnchor.chapterIdentity,
                    textSegmentIdentity: NovelTextSegmentIdentity(rawValue: imageAnchor.imageSegmentIdentity),
                    displayedTextOffset: 0,
                    chapterOrdinal: 0,
                    segmentProgress: 0,
                    authorID: imageAnchor.resolvedAuthorID,
                    readingModeHint: .paged
                )
            )
        case let .mangaImage(mangaAnchor):
            // The smart bit follows the board's *current* configuration when
            // the anchor recorded its fid (R13); legacy fid-less anchors keep
            // the pre-R13 smart-on assumption. See LikeMangaOpenTargetPolicy.
            Task {
                let boardReader = await settingsStore.load().boardReader
                appModel.requestMangaReader(
                    LikeMangaOpenTargetPolicy.launchContext(
                        anchor: mangaAnchor,
                        workID: work.id,
                        workTitle: workTitle,
                        boardReader: boardReader
                    )
                )
            }
        }
    }

    private func openNovelReader(threadID: String, workTitle: String, resumePoint: NovelResumePoint) {
        appModel.presentNovelReader(
            NovelLaunchContext(
                threadID: threadID,
                threadTitle: workTitle,
                source: .like,
                initialView: resumePoint.view,
                initialResumePoint: resumePoint,
                isPreview: true
            )
        )
    }
}

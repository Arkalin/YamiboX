import SwiftUI
import YamiboXCore

/// First-level Like list: one row per liked work, pushed from Mine.
struct LikeWorkListView: View {
    let likeDependencies: LikeDependencies
    let contentCoverStore: ContentCoverStore
    let favoriteLibraryStore: FavoriteLibraryStore
    let settingsStore: SettingsStore
    let appModel: YamiboAppModel

    @State private var summaries: [LikeWorkSummary] = []
    @State private var titlesByWorkKey: [LikeWorkKey: String] = [:]
    @State private var coverURLsByWorkKey: [LikeWorkKey: URL] = [:]
    @State private var searchText = ""
    @State private var pushedWorkKey: LikeWorkKey?

    @State private var isSelecting = false
    @State private var selectedWorkKeys: Set<LikeWorkKey> = []
    @State private var isShowingDeleteConfirmation = false

    private var filteredSummaries: [LikeWorkSummary] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return summaries }
        return summaries.filter { title(for: $0.workKey).localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        List(filteredSummaries, id: \.workKey) { summary in
            Button {
                if isSelecting {
                    toggleSelection(summary.workKey)
                } else {
                    pushedWorkKey = summary.workKey
                }
            } label: {
                row(for: summary)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .contentMargins(.top, 8, for: .scrollContent)
        // Kept permanently mounted rather than swapped for an empty-state
        // view — see the matching comment in LikeWorkItemsView.body for why
        // that swap makes `.searchable`'s search bar ghost during a push.
        .overlay {
            if summaries.isEmpty {
                ContentUnavailableView(L10n.string("likes.empty_state"), systemImage: "heart")
            } else if filteredSummaries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle(
            isSelecting
                ? L10n.string("likes.selected_count", selectedWorkKeys.count)
                : L10n.string("likes.section_title")
        )
        .navigationBarBackButtonHidden(isSelecting)
        .searchable(text: $searchText, prompt: L10n.string("likes.search_placeholder"))
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
                    if !summaries.isEmpty {
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
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: LikeStore.didChangeNotification)) { notification in
            guard let changeID = notification.userInfo?[LikeStore.changeIDUserInfoKey] as? String,
                  changeID == likeDependencies.likeStore.changeID else {
                return
            }
            Task { await load() }
        }
        .destructiveConfirmationDialog(
            L10n.string("likes.delete_selected_works_title"),
            isPresented: $isShowingDeleteConfirmation,
            message: L10n.string("likes.delete_selected_works_message", selectedWorkKeys.count)
        ) {
            Task { await deleteSelection() }
        }
        .sensoryFeedback(.selection, trigger: selectedWorkKeys)
    }

    private func row(for summary: LikeWorkSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LocalFavoriteCoverThumbnail(url: coverURLsByWorkKey[summary.workKey], title: title(for: summary.workKey))
                .frame(width: 92, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(title(for: summary.workKey))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                    Text(L10n.string("likes.item_count_format", summary.itemCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 128, alignment: .topLeading)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(minHeight: 128, alignment: .center)
                .opacity(isSelecting ? 0 : 1)
                .accessibilityHidden(isSelecting)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .favoriteSelectionEmphasis(
            isSelectionMode: isSelecting,
            isSelected: selectedWorkKeys.contains(summary.workKey),
            cornerRadius: 12
        )
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
        let keys = selectedWorkKeys
        for key in keys {
            try? await likeDependencies.likeStore.deleteAll(workKey: key)
        }
        setSelecting(false)
        await load()
    }

    private func load() async {
        async let fetchedSummaries = likeDependencies.likeStore.workSummaries()
        async let favoriteDocument = try? favoriteLibraryStore.load()
        let (summaries, document) = await (fetchedSummaries, favoriteDocument ?? FavoriteLibraryDocument())
        self.summaries = summaries

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
        titlesByWorkKey = titles
        coverURLsByWorkKey = covers
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
                    textSegmentIdentity: textAnchor.textSegmentIdentity,
                    displayedTextOffset: textAnchor.range.location,
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
                appModel.presentMangaReader(
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

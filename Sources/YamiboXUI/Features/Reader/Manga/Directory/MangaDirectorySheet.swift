import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaDirectorySheet: View {
    let panel: MangaDirectoryPanelPresentation
    let onClearFailure: @MainActor () -> Void
    let onSortOrderChange: (MangaDirectorySortOrder) -> Void
    let onGlobalSearch: () -> Void
    let onResetDirectory: () -> Void
    let onSaveCorrection: (MangaDirectoryEditDraft) -> Void
    let onDeleteChapters: (Set<String>) -> Void
    let onSelectChapter: (MangaChapter) -> Void
    let isEmbeddedInReaderPanel: Bool
    let isActive: Bool
    let onNavigationStateChange: ((ReaderAnnotationSegmentNavigationState) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = MangaDirectoryEditDraft(
        cleanBookName: "",
        primaryKeyword: "",
        secondaryKeyword: ""
    )
    @State private var didSeedDraft = false
    @State private var isCorrectionPresented = false
    @State private var isSelecting = false
    @State private var selectedChapterTIDs: Set<String> = []
    @State private var isCurrentChapterDeleteAlertPresented = false
    @State private var isBatchDeleteConfirmationPresented = false
    @State private var isResetConfirmationPresented = false
    @State private var layout = ChapterDirectoryLayout.list
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 72

    init(
        panel: MangaDirectoryPanelPresentation,
        onClearFailure: @escaping @MainActor () -> Void = {},
        onSortOrderChange: @escaping (MangaDirectorySortOrder) -> Void,
        onGlobalSearch: @escaping () -> Void,
        onResetDirectory: @escaping () -> Void,
        onSaveCorrection: @escaping (MangaDirectoryEditDraft) -> Void,
        onDeleteChapters: @escaping (Set<String>) -> Void,
        onSelectChapter: @escaping (MangaChapter) -> Void,
        isEmbeddedInReaderPanel: Bool = false,
        isActive: Bool = true,
        onNavigationStateChange: ((ReaderAnnotationSegmentNavigationState) -> Void)? = nil
    ) {
        self.panel = panel
        self.onClearFailure = onClearFailure
        self.onSortOrderChange = onSortOrderChange
        self.onGlobalSearch = onGlobalSearch
        self.onResetDirectory = onResetDirectory
        self.onSaveCorrection = onSaveCorrection
        self.onDeleteChapters = onDeleteChapters
        self.onSelectChapter = onSelectChapter
        self.isEmbeddedInReaderPanel = isEmbeddedInReaderPanel
        self.isActive = isActive
        self.onNavigationStateChange = onNavigationStateChange
    }

    var body: some View {
        Group {
            if isEmbeddedInReaderPanel {
                directoryContent
            } else {
                NavigationStack {
                    directoryContent
                        .toolbar(.visible, for: .navigationBar)
                }
            }
        }
    }

    private var directoryContent: some View {
        List {
                HStack {
                    MangaDirectorySortToggleButton(
                        sortOrder: panel.sortOrder,
                        onSortOrderChange: onSortOrderChange
                    )
                    Spacer(minLength: 0)
                    ChapterDirectoryLayoutPicker(layout: $layout)
                }
                .mangaDirectoryListRow(top: 10, bottom: 7)

                if panel.displayChapters.isEmpty {
                    ContentUnavailableView(L10n.string("manga.no_chapters"), systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .mangaDirectoryListRow(top: 5, bottom: 16)
                } else if layout == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumColumnWidth), spacing: 8)], spacing: 8) {
                        ForEach(panel.displayChapters) { chapter in
                            MangaDirectoryChapterGridItem(
                                chapter: chapter,
                                isCurrent: chapter.tid == panel.currentChapterTID,
                                isSelecting: isSelecting,
                                isSelected: selectedChapterTIDs.contains(chapter.tid),
                                action: {
                                    if isSelecting {
                                        toggleSelection(chapter)
                                    } else if chapter.tid != panel.currentChapterTID {
                                        onSelectChapter(chapter)
                                    }
                                }
                            )
                            .onLongPressGesture { beginSelection(chapter) }
                        }
                    }
                    .mangaDirectoryListRow(top: 5, bottom: 16)
                } else {
                    ForEach(panel.displayChapters) { chapter in
                        MangaDirectoryChapterRow(
                            chapter: chapter,
                            isCurrent: chapter.tid == panel.currentChapterTID,
                            isSelecting: isSelecting,
                            isSelected: selectedChapterTIDs.contains(chapter.tid),
                            onSelectChapter: onSelectChapter,
                            onToggleSelection: toggleSelection,
                            onBeginSelection: beginSelection
                        )
                        .mangaDirectoryListRow(top: 5, bottom: 5)
                        .deleteSwipeAction(isVisible: canDeleteChapterFromSwipe(chapter)) {
                            deleteChapter(chapter)
                        }
                    }
                }
        }
            .listStyle(.plain)
            .failureToast(message: isActive ? panel.errorMessage : nil,
                          details: panel.errorDetails,
                          eventID: panel.failureEventID, clear: onClearFailure)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting && !usesSystemSelectionBottomToolbar {
                    SelectionBottomToolbar(actions: selectionActions)
                        .selectionBottomToolbarCapsule()
                }
            }
            .mangaDirectoryNavigationTitle(
                isEmbeddedInReaderPanel: isEmbeddedInReaderPanel,
                isSelecting: isSelecting,
                selectedItemCount: selectedChapterTIDs.count
            )
            .toolbar {
                if isActive {
                    if isSelecting {
                        ToolbarItem(placement: .topBarLeading) {
                            SelectAllToolbarButton(
                                isSelectionComplete: visibleSelectionIsComplete,
                                isDisabled: panel.displayChapters.isEmpty,
                                toggle: toggleVisibleSelection
                            )
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.string("common.done"), action: exitSelectionMode)
                        }
                    } else if !isEmbeddedInReaderPanel {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel(L10n.string("common.close"))
                        }
                    }

                    if !isSelecting {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button {
                                    seedDraft(from: panel)
                                    isCorrectionPresented = true
                                } label: {
                                    Label(L10n.string("manga.correction_title"), systemImage: "pencil")
                                }
                                .disabled(panel.isUpdating)
                                Button {
                                    isSelecting = true
                                } label: {
                                    Label(L10n.string("manga.directory.edit"), systemImage: "checklist")
                                }
                                .disabled(panel.displayChapters.isEmpty || panel.isUpdating)
                                Button(action: onGlobalSearch) {
                                    Label(L10n.string("manga.global_search"), systemImage: "magnifyingglass")
                                }
                                .disabled(!panel.isUpdateButtonEnabled)
                                Divider()
                                Button(role: .destructive) {
                                    isResetConfirmationPresented = true
                                } label: {
                                    Label(L10n.string("manga.directory.reset"), systemImage: "arrow.counterclockwise")
                                }
                                .disabled(panel.isUpdating)
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .accessibilityLabel(L10n.string("common.more"))
                        }
                    }

                    if isSelecting && usesSystemSelectionBottomToolbar {
                        ToolbarItem(placement: .bottomBar) {
                            SelectionBottomToolbar(actions: selectionActions)
                        }
                    }
                }
            }
            .task {
                publishNavigationState()
                guard !didSeedDraft else { return }
                seedDraft(from: panel)
                didSeedDraft = true
            }
            .onChange(of: panel.displayChapters.map(\.tid)) { _, visibleTIDs in
                selectedChapterTIDs.formIntersection(Set(visibleTIDs))
            }
            .onChange(of: isSelecting) { _, _ in
                publishNavigationState()
            }
            .onChange(of: selectedChapterTIDs) { _, _ in
                publishNavigationState()
            }
            .sensoryFeedback(.selection, trigger: selectedChapterTIDs)
            .failureAlert(L10n.string("manga.delete_current_chapter_failed"),
                          message: L10n.string("manga.delete_current_chapter_failed_message"),
                          isPresented: $isCurrentChapterDeleteAlertPresented) {
                Button(L10n.string("common.ok"), role: .cancel) {}
            }
            .destructiveConfirmationDialog(
                L10n.string("manga.delete_selected_chapters_confirm_title", selectedChapterTIDs.count),
                isPresented: $isBatchDeleteConfirmationPresented,
                onConfirm: performDeleteSelectedChapters
            )
            .destructiveConfirmationAlert(
                L10n.string("manga.directory.reset_confirm_title"),
                isPresented: $isResetConfirmationPresented,
                actionTitle: L10n.string("manga.directory.reset"),
                message: L10n.string("manga.directory.reset_confirm_message"),
                onConfirm: onResetDirectory
            )
            .sheet(isPresented: $isCorrectionPresented) {
                MangaDirectoryCorrectionSheet(
                    draft: $draft,
                    onSaveCorrection: { draft in
                        onSaveCorrection(draft)
                        isCorrectionPresented = false
                    }
                )
                .presentationDetents(MangaDirectoryCorrectionSheet.presentationDetents)
            }
    }

    private var selectionActions: [SelectionToolbarAction] {
        [
            SelectionToolbarAction(
                id: "delete",
                title: L10n.string("common.delete"),
                systemImage: "trash",
                role: .destructive,
                isEnabled: !selectedChapterTIDs.isEmpty,
                action: deleteSelectedChapters
            )
        ]
    }

    private func seedDraft(from panel: MangaDirectoryPanelPresentation) {
        draft = panel.editDraft ?? MangaDirectoryEditDraft(
            cleanBookName: panel.directoryTitle,
            primaryKeyword: "",
            secondaryKeyword: ""
        )
    }

    /// Batch removal destroys every selected chapter in one tap, so it asks
    /// for confirmation first; single-chapter swipe deletion keeps the
    /// standard no-confirmation iOS behavior.
    private func deleteSelectedChapters() {
        let selectedTIDs = selectedChapterTIDs
        guard !selectedTIDs.isEmpty else {
            return
        }
        if selectedTIDs.contains(panel.currentChapterTID ?? "") {
            isCurrentChapterDeleteAlertPresented = true
            return
        }
        isBatchDeleteConfirmationPresented = true
    }

    private func performDeleteSelectedChapters() {
        let selectedTIDs = selectedChapterTIDs
        guard !selectedTIDs.isEmpty else {
            return
        }
        onDeleteChapters(selectedTIDs)
        exitSelectionMode()
    }

    private func deleteChapter(_ chapter: MangaChapter) {
        if chapter.tid == panel.currentChapterTID {
            isCurrentChapterDeleteAlertPresented = true
            return
        }
        onDeleteChapters([chapter.tid])
    }

    private var visibleChapterTIDs: Set<String> {
        Set(panel.displayChapters.map(\.tid))
    }

    private var visibleSelectionIsComplete: Bool {
        !panel.displayChapters.isEmpty && visibleChapterTIDs.isSubset(of: selectedChapterTIDs)
    }

    private func toggleVisibleSelection() {
        if visibleSelectionIsComplete {
            selectedChapterTIDs.subtract(visibleChapterTIDs)
        } else {
            selectedChapterTIDs.formUnion(visibleChapterTIDs)
        }
    }

    private func toggleSelection(_ chapter: MangaChapter) {
        if selectedChapterTIDs.contains(chapter.tid) {
            selectedChapterTIDs.remove(chapter.tid)
        } else {
            selectedChapterTIDs.insert(chapter.tid)
        }
    }

    private func beginSelection(_ chapter: MangaChapter) {
        guard !isSelecting else { return }
        isSelecting = true
        selectedChapterTIDs.insert(chapter.tid)
    }

    private func canDeleteChapterFromSwipe(_ chapter: MangaChapter) -> Bool {
        !isSelecting && chapter.tid != panel.currentChapterTID
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedChapterTIDs.removeAll()
    }

    private func publishNavigationState() {
        onNavigationStateChange?(
            ReaderAnnotationSegmentNavigationState(
                isSelecting: isSelecting,
                selectedItemCount: selectedChapterTIDs.count,
                selectionTitle: isSelecting
                    ? L10n.string("manga.directory.selected_count", selectedChapterTIDs.count)
                    : nil
            )
        )
    }
}

private extension View {
    @ViewBuilder
    func mangaDirectoryNavigationTitle(
        isEmbeddedInReaderPanel: Bool,
        isSelecting: Bool,
        selectedItemCount: Int
    ) -> some View {
        if isEmbeddedInReaderPanel {
            self
        } else {
            navigationTitle(
                isSelecting
                    ? L10n.string("manga.directory.selected_count", selectedItemCount)
                    : L10n.string("manga.directory")
            )
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    func mangaDirectoryListRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}


private struct MangaDirectorySortToggleButton: View {
    let sortOrder: MangaDirectorySortOrder
    let onSortOrderChange: (MangaDirectorySortOrder) -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        Button {
            onSortOrderChange(toggledSortOrder)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .foregroundStyle(sortOrder == .ascending ? appTheme.controlAccent : .gray.opacity(0.35))

                Image(systemName: "arrow.up")
                    .foregroundStyle(sortOrder == .descending ? appTheme.controlAccent : .gray.opacity(0.35))
            }
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(YamiboColors.SystemSurface.secondaryGroupedBackground)
            )
            .expandedHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("favorites.sort"))
        .accessibilityValue(sortOrder.title)
    }

    private var toggledSortOrder: MangaDirectorySortOrder {
        switch sortOrder {
        case .ascending: .descending
        case .descending: .ascending
        }
    }
}


private struct MangaDirectoryChapterGridItem: View {
    let chapter: MangaChapter
    let isCurrent: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.appTheme) private var appTheme
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 48

    var body: some View {
        Button(action: action) {
            Text(MangaChapterDisplayFormatter.displayNumber(for: chapter))
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 8)
                .padding(.vertical, isSelecting ? 12 : 0)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
                .foregroundStyle(isCurrent ? appTheme.controlAccent : .primary)
                .background(
                    isCurrent ? appTheme.controlAccent.opacity(0.12) : YamiboColors.SystemSurface.secondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    if isSelecting && isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(appTheme.controlAccent, lineWidth: 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? appTheme.controlAccent : .secondary)
                            .padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chapter.rawTitle)
        .accessibilityAddTraits(isSelected || (!isSelecting && isCurrent) ? .isSelected : [])
    }
}

private struct MangaDirectoryChapterRow: View {
    let chapter: MangaChapter
    let isCurrent: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onSelectChapter: (MangaChapter) -> Void
    let onToggleSelection: (MangaChapter) -> Void
    let onBeginSelection: (MangaChapter) -> Void

    @State private var isExpanded = false
    @State private var isTruncated = false
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(MangaChapterDisplayFormatter.displayNumber(for: chapter))
                .font(.caption.weight(.bold))
                .foregroundStyle(numberColor)
                .frame(width: 34, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TruncationAwareText(
                    chapter.rawTitle,
                    font: UIFont.preferredFont(forTextStyle: .subheadline),
                    lineLimit: isExpanded ? nil : 1,
                    isTruncated: $isTruncated
                )
                .font(.subheadline)
                .foregroundStyle(titleColor)
                .layoutPriority(1)

                if isTruncated {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? L10n.string("common.collapse") : L10n.string("common.expand"))
                            .lineLimit(1)
                            .fixedSize()
                            .expandedHitTarget(width: 0)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(expandButtonTint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .selectableCardRow(isSelecting: isSelecting, isSelected: isSelected, fill: backgroundColor) {
            if isSelecting {
                onToggleSelection(chapter)
            } else {
                guard !isCurrent else { return }
                onSelectChapter(chapter)
            }
        }
        .onLongPressGesture {
            onBeginSelection(chapter)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var titleColor: Color {
        isSelecting && !isSelected ? .secondary : .primary
    }

    private var numberColor: Color {
        if isSelecting {
            if isSelected {
                return isCurrent ? appTheme.controlAccent : .secondary
            }
            return isCurrent ? appTheme.controlAccent.opacity(0.45) : Color.secondary.opacity(0.55)
        }
        return isCurrent ? appTheme.controlAccent : .secondary
    }

    private var expandButtonTint: Color {
        isSelecting && !isSelected ? appTheme.controlAccent.opacity(0.45) : appTheme.controlAccent
    }

    private var backgroundColor: Color {
        if isCurrent {
            return appTheme.controlAccent.opacity(isSelecting && !isSelected ? 0.06 : 0.12)
        }
        return YamiboColors.SystemSurface.secondaryGroupedBackground
    }
}

private struct TruncationAwareText: View {
    let text: String
    let font: UIFont
    let lineLimit: Int?
    @Binding var isTruncated: Bool

    @State private var availableWidth: CGFloat = 0

    init(
        _ text: String,
        font: UIFont,
        lineLimit: Int?,
        isTruncated: Binding<Bool>
    ) {
        self.text = text
        self.font = font
        self.lineLimit = lineLimit
        _isTruncated = isTruncated
    }

    var body: some View {
        Text(text)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            updateAvailableWidth(proxy.size.width)
                        }
                        .onChange(of: proxy.size.width) { _, newValue in
                            updateAvailableWidth(newValue)
                        }
                }
            )
            .onChange(of: text) {
                updateTruncation()
            }
            .onChange(of: lineLimit) {
                updateTruncation()
            }
    }

    private func updateAvailableWidth(_ width: CGFloat) {
        availableWidth = width
        updateTruncation()
    }

    private func updateTruncation() {
        guard availableWidth > 0 else { return }
        let rect = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        .boundingRect(
            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        isTruncated = rect.height > (font.lineHeight * 1.2)
    }
}

struct MangaDirectoryUnavailableSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MangaDirectoryUnavailableContent()
                .navigationTitle(L10n.string("manga.directory"))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(L10n.string("common.close"))
                    }
                }
        }
    }
}

struct MangaDirectoryUnavailableContent: View {
    var body: some View {
        ContentUnavailableView(L10n.string("manga.no_chapters"), systemImage: "books.vertical")
    }
}
#endif

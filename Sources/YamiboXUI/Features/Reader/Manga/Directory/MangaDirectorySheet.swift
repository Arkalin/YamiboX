import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaDirectorySheet: View {
    let panel: MangaDirectoryPanelPresentation
    let onSortOrderChange: (MangaDirectorySortOrder) -> Void
    let onUpdateDirectory: () -> Void
    let onResetDirectory: () -> Void
    let onSaveCorrection: (MangaDirectoryEditDraft) -> Void
    let onDeleteChapters: (Set<String>) -> Void
    let onSelectChapter: (MangaChapter) -> Void

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

    var body: some View {
        NavigationStack {
            List {
                MangaDirectoryMetadataSection(
                    panel: panel,
                    isSelecting: isSelecting,
                    onUpdateDirectory: onUpdateDirectory,
                    onEditDirectory: {
                        seedDraft(from: panel)
                        isCorrectionPresented = true
                    }
                )
                .mangaDirectoryListRow(top: 16, bottom: 10)

                MangaDirectoryChapterControlsRow(
                    isSelecting: isSelecting,
                    hasChapters: !panel.displayChapters.isEmpty,
                    visibleSelectionIsComplete: visibleSelectionIsComplete,
                    sortOrder: panel.sortOrder,
                    onSortOrderChange: onSortOrderChange,
                    onToggleVisibleSelection: toggleVisibleSelection,
                    onToggleSelectionMode: {
                        if isSelecting {
                            exitSelectionMode()
                        } else {
                            isSelecting = true
                        }
                    }
                )
                .mangaDirectoryListRow(top: 10, bottom: 7)

                if panel.displayChapters.isEmpty {
                    ContentUnavailableView(L10n.string("manga.no_chapters"), systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
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
            .scrollContentBackground(.hidden)
            .background(YamiboColors.SystemSurface.groupedBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting && !usesSystemSelectionBottomToolbar {
                    SelectionBottomToolbar(actions: selectionActions)
                        .selectionBottomToolbarCapsule()
                }
            }
            .navigationTitle(
                isSelecting
                    ? L10n.string("manga.directory.selected_count", selectedChapterTIDs.count)
                    : L10n.string("manga.directory")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.string("common.close"))
                }

                if !isSelecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isResetConfirmationPresented = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .disabled(panel.isUpdating)
                        .accessibilityLabel(L10n.string("manga.directory.reset"))
                    }
                }

                if isSelecting && usesSystemSelectionBottomToolbar {
                    ToolbarItem(placement: .bottomBar) {
                        SelectionBottomToolbar(actions: selectionActions)
                    }
                }
            }
            .task {
                guard !didSeedDraft else { return }
                seedDraft(from: panel)
                didSeedDraft = true
            }
            .onChange(of: panel.displayChapters.map(\.tid)) { _, visibleTIDs in
                selectedChapterTIDs.formIntersection(Set(visibleTIDs))
            }
            .sensoryFeedback(.selection, trigger: selectedChapterTIDs)
            .alert(L10n.string("manga.delete_current_chapter_failed"), isPresented: $isCurrentChapterDeleteAlertPresented) {
                Button(L10n.string("common.ok"), role: .cancel) {}
            } message: {
                Text(L10n.string("manga.delete_current_chapter_failed_message"))
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
}

private extension View {
    func mangaDirectoryListRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct MangaDirectoryMetadataSection: View {
    let panel: MangaDirectoryPanelPresentation
    let isSelecting: Bool
    let onUpdateDirectory: () -> Void
    let onEditDirectory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                onEditDirectory()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(panel.directoryTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if !isSelecting {
                        Image(systemName: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isSelecting)

            HStack(alignment: .center, spacing: 12) {
                if let latestChapterText = panel.latestChapterText {
                    Text(latestChapterText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(panel.updateButtonTitle) {
                    onUpdateDirectory()
                }
                .buttonStyle(.borderedProminent)
                .tint(panel.isSearchMode ? .indigo : .accentColor)
                .disabled(!panel.isUpdateButtonEnabled || isSelecting)
            }

            if let errorMessage = panel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(YamiboColors.SystemSurface.secondaryGroupedBackground)
        )
    }
}

private struct MangaDirectoryChapterControlsRow: View {
    let isSelecting: Bool
    let hasChapters: Bool
    let visibleSelectionIsComplete: Bool
    let sortOrder: MangaDirectorySortOrder
    let onSortOrderChange: (MangaDirectorySortOrder) -> Void
    let onToggleVisibleSelection: () -> Void
    let onToggleSelectionMode: () -> Void

    var body: some View {
        HStack {
            if isSelecting {
                SelectAllToolbarButton(
                    isSelectionComplete: visibleSelectionIsComplete,
                    isDisabled: !hasChapters,
                    expandsHitTarget: true,
                    toggle: onToggleVisibleSelection
                )
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
            } else {
                MangaDirectorySortToggleButton(
                    sortOrder: sortOrder,
                    onSortOrderChange: onSortOrderChange
                )
            }

            Spacer(minLength: 0)

            MangaDirectorySelectionToggleButton(isSelecting: isSelecting) {
                onToggleSelectionMode()
            }
        }
        .frame(height: 38, alignment: .center)
    }
}

private struct MangaDirectorySortToggleButton: View {
    let sortOrder: MangaDirectorySortOrder
    let onSortOrderChange: (MangaDirectorySortOrder) -> Void

    var body: some View {
        Button {
            onSortOrderChange(toggledSortOrder)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .foregroundStyle(sortOrder == .ascending ? Color.accentColor : .gray.opacity(0.35))

                Image(systemName: "arrow.up")
                    .foregroundStyle(sortOrder == .descending ? Color.accentColor : .gray.opacity(0.35))
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

private struct MangaDirectorySelectionToggleButton: View {
    let isSelecting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isSelecting {
                    Text(L10n.string("common.done"))
                        .font(.subheadline.weight(.semibold))
                } else {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .expandedHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelecting ? L10n.string("common.done") : L10n.string("common.select"))
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
                return isCurrent ? .accentColor : .secondary
            }
            return isCurrent ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.55)
        }
        return isCurrent ? .accentColor : .secondary
    }

    private var expandButtonTint: Color {
        isSelecting && !isSelected ? Color.accentColor.opacity(0.45) : .accentColor
    }

    private var backgroundColor: Color {
        if isCurrent {
            return Color.accentColor.opacity(isSelecting && !isSelected ? 0.06 : 0.12)
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
            ContentUnavailableView(L10n.string("manga.no_chapters"), systemImage: "books.vertical")
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
#endif

import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderCachePanel: View {
    @ObservedObject var cache: NovelReaderCacheCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var isSelecting = false
    @State private var selectedViews: Set<Int> = []
    @State private var isQueuePresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var queueViewModel: OfflineCacheQueueViewModel

    init(cache: NovelReaderCacheCoordinator) {
        _cache = ObservedObject(wrappedValue: cache)
        _queueViewModel = State(initialValue: cache.makeOfflineCacheQueueViewModel())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    NovelReaderCachePageSection(
                        rows: rows,
                        isSelecting: $isSelecting,
                        selectedViews: $selectedViews,
                        isAllSelected: selectionState.isAllSelected,
                        onToggleAll: toggleAll
                    )
                }
                .padding(16)
            }
            .background(YamiboColors.SystemSurface.groupedBackground)
            .navigationTitle(
                isSelecting
                    ? L10n.string("reader.cache_management.selected_count", selectedViews.count)
                    : L10n.string("reader.cache_management")
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

                ToolbarItem(placement: .topBarTrailing) {
                    ReaderCacheQueueToolbarButton(
                        entryCount: cache.state.queueEntryCount,
                        action: showQueue
                    )
                }

                if isSelecting && usesSystemSelectionBottomToolbar {
                    ToolbarItem(placement: .bottomBar) {
                        SelectionBottomToolbar(actions: selectionActions)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting && !usesSystemSelectionBottomToolbar {
                    SelectionBottomToolbar(actions: selectionActions)
                        .selectionBottomToolbarCapsule()
                }
            }
            .sheet(isPresented: $isQueuePresented) {
                OfflineCacheQueueSheet(viewModel: queueViewModel)
            }
            .destructiveConfirmationDialog(
                L10n.string(
                    "reader.cache.delete_selected_confirm_title",
                    selectionState.cachedSelectedViews.count
                ),
                isPresented: $isDeleteConfirmationPresented,
                onConfirm: performDeleteSelection
            )
            .task {
                await cache.refresh()
            }
            .refreshable {
                await cache.refresh()
            }
            .sensoryFeedback(.selection, trigger: selectedViews)
        }
    }

    private var rows: [NovelReaderCachePageRow] {
        cache.allCacheableViews.map { view in
            NovelReaderCachePageRow(
                view: view,
                status: cache.status(for: view),
                updateTime: cache.updateTime(for: view)
            )
        }
    }

    private var selectionState: NovelReaderCacheSelectionState {
        cache.selectionState(for: selectedViews)
    }

    private var selectionActions: [SelectionToolbarAction] {
        [
            SelectionToolbarAction(
                id: "cache",
                title: L10n.string("reader.cache_action.cache"),
                systemImage: "square.and.arrow.down",
                isEnabled: selectionState.canCache,
                action: cacheSelection
            ),
            SelectionToolbarAction(
                id: "update",
                title: L10n.string("reader.cache_action.update"),
                systemImage: "arrow.triangle.2.circlepath",
                isEnabled: selectionState.canUpdate,
                action: updateSelection
            ),
            SelectionToolbarAction(
                id: "delete",
                title: L10n.string("common.delete"),
                systemImage: "trash",
                role: .destructive,
                isEnabled: selectionState.canDelete,
                action: deleteSelection
            )
        ]
    }

    private func toggleAll() {
        if selectionState.isAllSelected {
            selectedViews = []
        } else {
            selectedViews = Set(cache.allCacheableViews)
        }
    }

    private func cacheSelection() {
        cache.startCaching(views: selectionState.uncachedSelectedViews)
        exitSelectionMode()
    }

    private func updateSelection() {
        cache.updateCachedViews(selectionState.updatableSelectedViews)
        exitSelectionMode()
    }

    /// Batch removal is destructive (re-downloading has real cost offline),
    /// so it goes through a confirmation before executing.
    private func deleteSelection() {
        isDeleteConfirmationPresented = true
    }

    private func performDeleteSelection() {
        let targets = selectionState.cachedSelectedViews
        Task { @MainActor in
            await cache.deleteCachedViews(targets)
            exitSelectionMode()
        }
    }

    @MainActor
    private func exitSelectionMode() {
        isSelecting = false
        selectedViews = []
    }

    private func showQueue() {
        isQueuePresented = true
    }
}

private struct NovelReaderCachePageRow: Identifiable, Equatable {
    let view: Int
    let status: NovelOfflineCacheViewStatus
    let updateTime: Date?

    var id: Int { view }
}

private struct NovelReaderCachePageSection: View {
    let rows: [NovelReaderCachePageRow]
    @Binding var isSelecting: Bool
    @Binding var selectedViews: Set<Int>
    let isAllSelected: Bool
    let onToggleAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReaderCacheSelectionHeader(
                sectionTitle: L10n.string("reader.cache_page_section"),
                isSelecting: isSelecting,
                isAllSelected: isAllSelected,
                isEmpty: rows.isEmpty,
                onToggleAll: onToggleAll,
                onToggleSelectionMode: toggleSelectionMode
            )
            .frame(height: 38, alignment: .center)

            if rows.isEmpty {
                ContentUnavailableView(L10n.string("reader.no_cacheable_pages"), systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { row in
                        NovelReaderCachePageRowView(
                            row: row,
                            isSelecting: isSelecting,
                            isSelected: selectedViews.contains(row.view),
                            onToggleSelection: {
                                toggleSelection(row.view)
                            }
                        )
                    }
                }
            }
        }
    }

    private func toggleSelectionMode() {
        if isSelecting {
            isSelecting = false
            selectedViews = []
        } else {
            isSelecting = true
        }
    }

    private func toggleSelection(_ view: Int) {
        if !isSelecting {
            isSelecting = true
            selectedViews.insert(view)
            return
        }

        if selectedViews.contains(view) {
            selectedViews.remove(view)
        } else {
            selectedViews.insert(view)
        }
    }
}


private struct NovelReaderCachePageRowView: View {
    let row: NovelReaderCachePageRow
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.string("reader.page_number_spaced", row.view))
                .font(.subheadline)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                NovelReaderCacheStateBadge(status: row.status, isDimmed: dimming.isDimmed)

                if let updateTime = row.updateTime {
                    Text(L10n.string("reader.cache_updated_at", updateTime.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption2)
                        .foregroundStyle(dimming.secondaryColor)
                }
            }
        }
        .selectableCardRow(isSelecting: isSelecting, isSelected: isSelected) {
            onToggleSelection()
        }
    }

    private var dimming: SelectionRowDimming {
        SelectionRowDimming(isSelecting: isSelecting, isSelected: isSelected)
    }

    private var titleColor: Color {
        dimming.titleColor
    }
}

private struct NovelReaderCacheStateBadge: View {
    let status: NovelOfflineCacheViewStatus
    let isDimmed: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var title: String {
        switch status {
        case .cached:
            L10n.string("reader.cached")
        case .uncached:
            L10n.string("reader.uncached")
        case .caching:
            L10n.string("reader.caching")
        }
    }

    private var systemImage: String {
        switch status {
        case .cached:
            "checkmark.seal.fill"
        case .uncached:
            "icloud"
        case .caching:
            "arrow.down.circle.fill"
        }
    }

    private var tint: Color {
        if isDimmed {
            return Color.secondary.opacity(0.55)
        }
        switch status {
        case .cached:
            return Color.green
        case .uncached:
            return Color.secondary
        case .caching:
            return Color.orange
        }
    }
}


struct NovelReaderCacheProgressSheet: View {
    @ObservedObject var cache: NovelReaderCacheCoordinator
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)

                VStack(spacing: 10) {
                    Text(titleText)
                        .font(.title3.weight(.semibold))

                    Text(detailText)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    if let summary = cache.state.operation.summaryMessage, cache.state.operation.isFinished {
                        Text(summary)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle(L10n.string("reader.cache_progress"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        if cache.state.operation.isFinished {
                            Button(L10n.string("common.done")) {
                                cache.dismissProgress()
                                onClose()
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(L10n.string("reader.run_in_background")) {
                                cache.hideProgress()
                                onClose()
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)

                            Button(L10n.string("common.stop"), role: .destructive) {
                                cache.stopCaching()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var progressValue: Double {
        guard cache.state.operation.totalCount > 0 else { return 0 }
        return Double(cache.state.operation.completedCount) / Double(cache.state.operation.totalCount)
    }

    private var titleText: String {
        switch cache.state.operation.status {
        case .idle:
            return L10n.string("reader.cache_status.ready")
        case .running:
            return L10n.string("reader.cache_status.running")
        case .completed:
            return L10n.string("reader.cache_status.completed")
        case .cancelled:
            return L10n.string("reader.cache_status.cancelled")
        }
    }

    private var detailText: String {
        if cache.state.operation.isFinished {
            return L10n.string("reader.cache_detail.completed", cache.state.operation.completedCount, max(cache.state.operation.totalCount, 1))
        }

        if let currentView = cache.state.operation.currentView {
            return L10n.string("reader.cache_detail.running", currentView, cache.state.operation.completedCount, max(cache.state.operation.totalCount, 1))
        }

        return L10n.string("reader.cache_detail.ready")
    }
}
#endif

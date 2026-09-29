import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderDownloadPanel: View {
    @ObservedObject var download: NovelReaderDownloadCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var isSelecting = false
    @State private var selectedViews: Set<Int> = []
    @State private var isQueuePresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var queueViewModel: DownloadQueueViewModel
    @State private var managementViewModel: DownloadManagementViewModel

    init(download: NovelReaderDownloadCoordinator) {
        _download = ObservedObject(wrappedValue: download)
        _queueViewModel = State(initialValue: download.makeDownloadQueueViewModel())
        _managementViewModel = State(initialValue: download.makeDownloadManagementViewModel())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ReaderDownloadSelectionSection(
                        rows: rows,
                        sectionTitle: L10n.string("reader.download_page_section"),
                        emptyTitle: L10n.string("reader.no_downloadable_pages"),
                        emptySystemImage: "doc.text",
                        isSelecting: $isSelecting,
                        selection: $selectedViews,
                        isAllSelected: selectionState.isAllSelected,
                        onToggleAll: toggleAll
                    ) { row, isSelected in
                        NovelReaderDownloadPageRowView(
                            row: row, isSelecting: isSelecting, isSelected: isSelected
                        )
                    }
                }
                .padding(16)
            }
            .background(YamiboColors.SystemSurface.groupedBackground)
            .navigationTitle(
                isSelecting
                    ? L10n.string("reader.download_management.selected_count", selectedViews.count)
                    : L10n.string("reader.download_management")
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
                    ReaderDownloadQueueToolbarButton(
                        entryCount: download.state.queueEntryCount,
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
                DownloadQueueSheet(viewModel: queueViewModel, management: managementViewModel)
            }
            .destructiveConfirmationDialog(
                L10n.string(
                    "reader.download.delete_selected_confirm_title",
                    selectionState.downloadedSelectedViews.count
                ),
                isPresented: $isDeleteConfirmationPresented,
                onConfirm: performDeleteSelection
            )
            .task {
                await download.refresh()
            }
            .refreshable {
                await download.refresh()
            }
            .sensoryFeedback(.selection, trigger: selectedViews)
        }
    }

    private var rows: [NovelReaderDownloadPageRow] {
        download.allDownloadableViews.map { view in
            NovelReaderDownloadPageRow(
                view: view,
                status: download.status(for: view),
                updateTime: download.updateTime(for: view)
            )
        }
    }

    private var selectionState: NovelReaderDownloadSelectionState {
        download.selectionState(for: selectedViews)
    }

    private var selectionActions: [SelectionToolbarAction] {
        [
            SelectionToolbarAction(
                id: "download",
                title: L10n.string("reader.download_action.download"),
                systemImage: "square.and.arrow.down",
                isEnabled: selectionState.canDownload,
                action: downloadSelection
            ),
            SelectionToolbarAction(
                id: "update",
                title: L10n.string("reader.download_action.update"),
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
            selectedViews = Set(download.allDownloadableViews)
        }
    }

    private func downloadSelection() {
        download.startDownloading(views: selectionState.notDownloadedSelectedViews)
        exitSelectionMode()
    }

    private func updateSelection() {
        download.updateDownloadedViews(selectionState.updatableSelectedViews)
        exitSelectionMode()
    }

    /// Batch removal is destructive (re-downloading has real cost offline),
    /// so it goes through a confirmation before executing.
    private func deleteSelection() {
        isDeleteConfirmationPresented = true
    }

    private func performDeleteSelection() {
        let targets = selectionState.downloadedSelectedViews
        Task { @MainActor in
            await download.deleteDownloadedViews(targets)
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

private struct NovelReaderDownloadPageRow: Identifiable, Equatable {
    let view: Int
    let status: NovelDownloadViewStatus
    let updateTime: Date?

    var id: Int { view }
}

private struct NovelReaderDownloadPageRowView: View {
    let row: NovelReaderDownloadPageRow
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.string("reader.page_number_spaced", row.view))
                .font(.subheadline)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                ReaderDownloadStateBadge(
                    state: row.status.downloadDisplayState,
                    notDownloadedTitle: L10n.string("reader.not_downloaded"),
                    downloadingTitle: L10n.string("reader.downloading"),
                    isDimmed: dimming.isDimmed
                )

                if let updateTime = row.updateTime {
                    Text(L10n.string("reader.download_updated_at", updateTime.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption2)
                        .foregroundStyle(dimming.secondaryColor)
                }
            }
        }
    }

    private var dimming: SelectionRowDimming {
        SelectionRowDimming(isSelecting: isSelecting, isSelected: isSelected)
    }

    private var titleColor: Color {
        dimming.titleColor
    }
}

private extension NovelDownloadViewStatus {
    var downloadDisplayState: ReaderDownloadDisplayState {
        switch self {
        case .downloaded: .downloaded
        case .notDownloaded: .notDownloaded
        case .downloading: .downloading
        }
    }
}


struct NovelReaderDownloadProgressSheet: View {
    @ObservedObject var download: NovelReaderDownloadCoordinator
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

                    if let summary = download.state.operation.summaryMessage, download.state.operation.isFinished {
                        Text(summary)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle(L10n.string("reader.download_progress"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        if download.state.operation.isFinished {
                            Button(L10n.string("common.done")) {
                                download.dismissProgress()
                                onClose()
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(L10n.string("reader.run_in_background")) {
                                download.hideProgress()
                                onClose()
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)

                            Button(L10n.string("common.stop"), role: .destructive) {
                                download.stopDownloading()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var progressValue: Double {
        guard download.state.operation.totalCount > 0 else { return 0 }
        return Double(download.state.operation.completedCount) / Double(download.state.operation.totalCount)
    }

    private var titleText: String {
        switch download.state.operation.status {
        case .idle:
            return L10n.string("reader.download_status.ready")
        case .running:
            return L10n.string("reader.download_status.running")
        case .completed:
            return L10n.string("reader.download_status.completed")
        case .cancelled:
            return L10n.string("reader.download_status.cancelled")
        }
    }

    private var detailText: String {
        if download.state.operation.isFinished {
            return L10n.string("reader.download_detail.completed", download.state.operation.completedCount, max(download.state.operation.totalCount, 1))
        }

        if let currentView = download.state.operation.currentView {
            return L10n.string("reader.download_detail.running", currentView, download.state.operation.completedCount, max(download.state.operation.totalCount, 1))
        }

        return L10n.string("reader.download_detail.ready")
    }
}
#endif

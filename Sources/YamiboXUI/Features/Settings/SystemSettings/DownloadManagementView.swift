import SwiftUI
import YamiboXCore

struct DownloadManagementView: View {
    let viewModel: DownloadManagementViewModel
    @State private var selectedGroupID: DownloadGroupID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let failure = viewModel.loadFailure {
                    LoadFailureView(message: L10n.string("common.load_failed"), details: failure) {
                        Task { await viewModel.refreshDownloadManagement() }
                    }
                }
                if viewModel.downloadManagementIsEmpty && viewModel.loadFailure == nil && viewModel.activeAction != .loading {
                    DownloadManagementEmptyState()
                } else if !viewModel.downloadManagementIsEmpty {
                    DownloadStorageSummary(
                        rows: viewModel.isDownloadManagementSelectionMode
                            ? viewModel.downloadManagementRows.filter { viewModel.selectedDownloadGroupIDs.contains($0.id) }
                            : viewModel.downloadManagementRows,
                        isSelecting: viewModel.isDownloadManagementSelectionMode
                    )
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.downloadManagementRows) { row in
                            DownloadManagementGroupRowView(
                                row: row,
                                isSelecting: viewModel.isDownloadManagementSelectionMode,
                                isSelected: viewModel.selectedDownloadGroupIDs.contains(row.id),
                                open: {
                                    viewModel.setDownloadManagementSelectionMode(false)
                                    selectedGroupID = row.id
                                },
                                select: {
                                    viewModel.toggleDownloadManagementSelection(id: row.id)
                                },
                                delete: {
                                    viewModel.requestDownloadGroupDeletion(id: row.id)
                                }
                            )
                        }
                    }
                }
            }
            .padding(16)
            .disabled(viewModel.activeAction == .clearingDownload)
        }
        .background(YamiboColors.SystemSurface.groupedBackground)
        .navigationTitle(
            viewModel.isDownloadManagementSelectionMode
                ? L10n.string("settings.download.selected_count", viewModel.selectedDownloadGroupIDs.count)
                : L10n.string("settings.download.title")
        )
        .navigationBarBackButtonHidden(viewModel.isDownloadManagementSelectionMode)
        .task {
            await viewModel.refreshDownloadManagement()
        }
        .refreshable {
            await viewModel.refreshDownloadManagement()
        }
        .navigationDestination(item: $selectedGroupID) { groupID in
            DownloadManagementGroupScreen(
                viewModel: viewModel,
                groupID: groupID
            )
        }
        .toolbar {
            if viewModel.isDownloadManagementSelectionMode {
                ToolbarItem(placement: .cancellationAction) {
                    DownloadManagementSelectAllButton(viewModel: viewModel)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if !viewModel.downloadManagementIsEmpty {
                    SelectionModeToggleButton(
                        isSelecting: viewModel.isDownloadManagementSelectionMode,
                        isDisabled: viewModel.activeAction == .clearingDownload
                    ) {
                        viewModel.setDownloadManagementSelectionMode(
                            !viewModel.isDownloadManagementSelectionMode
                        )
                    }
                }
            }

            #if os(iOS)
            if viewModel.isDownloadManagementSelectionMode && usesSystemSelectionBottomToolbar {
                ToolbarItem(placement: .bottomBar) {
                    SelectionBottomToolbar(
                        actions: DownloadManagementSelectionActions.delete(
                            actionState: viewModel.downloadManagementSelectionActionState,
                            onDelete: viewModel.requestSelectedDownloadGroupDeletion
                        )
                    )
                }
            }
            #endif
        }
        .toolbar(viewModel.isDownloadManagementSelectionMode ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isDownloadManagementSelectionMode && !usesSystemSelectionBottomToolbar {
                SelectionBottomToolbar(
                    actions: DownloadManagementSelectionActions.delete(
                        actionState: viewModel.downloadManagementSelectionActionState,
                        onDelete: viewModel.requestSelectedDownloadGroupDeletion
                    )
                )
                .selectionBottomToolbarCapsule()
            }
        }
        .overlay {
            if (viewModel.activeAction == .loading && viewModel.downloadManagementIsEmpty)
                || viewModel.activeAction == .clearingDownload {
                ProgressView(
                    viewModel.activeAction == .clearingDownload
                        ? L10n.string("common.deleting")
                        : L10n.string("common.loading")
                )
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .sensoryFeedback(.selection, trigger: viewModel.selectedDownloadGroupIDs)
        .downloadManagementAlert(viewModel: viewModel)
    }
}

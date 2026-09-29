import SwiftUI
import YamiboXCore

struct DownloadManagementView: View {
    let viewModel: DownloadManagementViewModel
    let queue: DownloadQueueViewModel
    let openQueue: () -> Void
    @State private var selectedGroupID: DownloadGroupID?

    var body: some View {
        List {
            if !viewModel.isDownloadManagementSelectionMode {
                Section {
                    Button(action: openQueue) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 20))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.string("mine.download_queue")).foregroundStyle(.primary)
                                Text(queue.summaryText).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(viewModel.activeAction == .clearingDownload)
                }
            }
            Section(L10n.string("downloads.local_contents")) {
                if let failure = viewModel.loadFailure {
                    LoadFailureView(message: L10n.string("common.load_failed"), details: failure) {
                        Task { await viewModel.refreshDownloadManagement() }
                    }
                }
                if viewModel.downloadManagementIsEmpty && viewModel.loadFailure == nil && viewModel.activeAction != .loading {
                    DownloadManagementEmptyState()
                } else if !viewModel.downloadManagementIsEmpty {
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
            .disabled(viewModel.activeAction == .clearingDownload)
        }
        .listStyle(.insetGrouped)
        .yamiboInlineNavigationTitleDisplayMode()
        .navigationTitle(
            viewModel.isDownloadManagementSelectionMode
                ? L10n.string("settings.download.selected_count", viewModel.selectedDownloadGroupIDs.count)
                : L10n.string("settings.download.title")
        )
        .navigationBarBackButtonHidden(viewModel.isDownloadManagementSelectionMode)
        .task {
            await viewModel.observeUpdates()
        }
        .task { await viewModel.observeSession() }
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
                || viewModel.activeAction == .clearingDownload
            {
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
        .downloadManagementAlert(viewModel: viewModel, isActive: selectedGroupID == nil)
        .onDisappear { viewModel.setDownloadManagementSelectionMode(false) }
    }
}

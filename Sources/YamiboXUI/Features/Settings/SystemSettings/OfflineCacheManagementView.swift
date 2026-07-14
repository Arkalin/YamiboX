import SwiftUI
import YamiboXCore

struct OfflineCacheManagementView: View {
    @ObservedObject var viewModel: SystemSettingsViewModel
    @State private var selectedGroupID: OfflineCacheGroupID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.offlineCacheManagementIsEmpty {
                    OfflineCacheManagementEmptyState()
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.offlineCacheManagementRows) { row in
                            OfflineCacheManagementGroupRowView(
                                row: row,
                                isSelecting: viewModel.isOfflineCacheManagementSelectionMode,
                                isSelected: viewModel.selectedOfflineCacheGroupIDs.contains(row.id),
                                open: {
                                    viewModel.setOfflineCacheManagementSelectionMode(false)
                                    selectedGroupID = row.id
                                },
                                select: {
                                    viewModel.toggleOfflineCacheManagementSelection(id: row.id)
                                },
                                delete: {
                                    viewModel.requestOfflineCacheGroupDeletion(id: row.id)
                                }
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(YamiboColors.SystemSurface.groupedBackground)
        .navigationTitle(
            viewModel.isOfflineCacheManagementSelectionMode
                ? L10n.string("settings.offline_cache.selected_count", viewModel.selectedOfflineCacheGroupIDs.count)
                : L10n.string("settings.offline_cache.title")
        )
        .navigationBarBackButtonHidden(viewModel.isOfflineCacheManagementSelectionMode)
        .task {
            await viewModel.refreshOfflineCacheManagement()
        }
        .refreshable {
            await viewModel.refreshOfflineCacheManagement()
        }
        .navigationDestination(item: $selectedGroupID) { groupID in
            OfflineCacheManagementGroupScreen(
                viewModel: viewModel,
                groupID: groupID
            )
        }
        .toolbar {
            if viewModel.isOfflineCacheManagementSelectionMode {
                ToolbarItem(placement: .cancellationAction) {
                    OfflineCacheManagementSelectAllButton(viewModel: viewModel)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if !viewModel.offlineCacheManagementIsEmpty {
                    SelectionModeToggleButton(
                        isSelecting: viewModel.isOfflineCacheManagementSelectionMode,
                        isDisabled: viewModel.activeAction == .clearingOfflineCache
                    ) {
                        viewModel.setOfflineCacheManagementSelectionMode(
                            !viewModel.isOfflineCacheManagementSelectionMode
                        )
                    }
                }
            }

            #if os(iOS)
            if viewModel.isOfflineCacheManagementSelectionMode && usesSystemSelectionBottomToolbar {
                ToolbarItem(placement: .bottomBar) {
                    SelectionBottomToolbar(
                        actions: OfflineCacheManagementSelectionActions.delete(
                            actionState: viewModel.offlineCacheManagementSelectionActionState,
                            onDelete: viewModel.requestSelectedOfflineCacheGroupDeletion
                        )
                    )
                }
            }
            #endif
        }
        .toolbar(viewModel.isOfflineCacheManagementSelectionMode ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isOfflineCacheManagementSelectionMode && !usesSystemSelectionBottomToolbar {
                SelectionBottomToolbar(
                    actions: OfflineCacheManagementSelectionActions.delete(
                        actionState: viewModel.offlineCacheManagementSelectionActionState,
                        onDelete: viewModel.requestSelectedOfflineCacheGroupDeletion
                    )
                )
                .selectionBottomToolbarCapsule()
            }
        }
        .overlay {
            if viewModel.activeAction == .loading || viewModel.activeAction == .clearingOfflineCache {
                ProgressView(
                    viewModel.activeAction == .clearingOfflineCache
                        ? L10n.string("common.deleting")
                        : L10n.string("common.loading")
                )
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .sensoryFeedback(.selection, trigger: viewModel.selectedOfflineCacheGroupIDs)
        .offlineCacheManagementAlert(viewModel: viewModel)
    }
}

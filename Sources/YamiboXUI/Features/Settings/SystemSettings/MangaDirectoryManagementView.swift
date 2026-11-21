import SwiftUI
import YamiboXCore

struct MangaDirectoryManagementView: View {
    let viewModel: MangaDirectoryManagementViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.mangaDirectoryManagementIsEmpty {
                    MangaDirectoryManagementEmptyState()
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.mangaDirectoryManagementRows) { row in
                            MangaDirectoryManagementRowView(
                                row: row,
                                isSelecting: viewModel.isMangaDirectoryManagementSelectionMode,
                                isSelected: viewModel.selectedMangaDirectoryIDs.contains(row.id),
                                select: {
                                    viewModel.toggleMangaDirectoryManagementSelection(id: row.id)
                                },
                                delete: {
                                    viewModel.requestMangaDirectoryDeletion(id: row.id)
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
            viewModel.isMangaDirectoryManagementSelectionMode
                ? L10n.string("settings.manga_directory.selected_count", viewModel.selectedMangaDirectoryIDs.count)
                : L10n.string("settings.manga_directory.title")
        )
        .navigationBarBackButtonHidden(viewModel.isMangaDirectoryManagementSelectionMode)
        .task {
            await viewModel.refreshMangaDirectoryManagement()
        }
        .task { await viewModel.observeSyncSettings() }
        .task { await viewModel.observeDirectoryChanges() }
        .refreshable {
            await viewModel.refreshMangaDirectoryManagement()
        }
        .toolbar {
            if viewModel.isMangaDirectoryManagementSelectionMode {
                ToolbarItem(placement: .cancellationAction) {
                    MangaDirectoryManagementSelectAllButton(viewModel: viewModel)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if !viewModel.mangaDirectoryManagementIsEmpty {
                    SelectionModeToggleButton(
                        isSelecting: viewModel.isMangaDirectoryManagementSelectionMode,
                        isDisabled: viewModel.activeAction == .clearingMangaDirectory
                    ) {
                        viewModel.setMangaDirectoryManagementSelectionMode(
                            !viewModel.isMangaDirectoryManagementSelectionMode
                        )
                    }
                }
            }

            #if os(iOS)
            if viewModel.isMangaDirectoryManagementSelectionMode && usesSystemSelectionBottomToolbar {
                ToolbarItem(placement: .bottomBar) {
                    SelectionBottomToolbar(
                        actions: MangaDirectoryManagementSelectionActions.delete(
                            selectedCount: viewModel.selectedMangaDirectoryCount,
                            canDelete: viewModel.mangaDirectoryManagementCanDeleteSelected,
                            onDelete: viewModel.requestSelectedMangaDirectoryDeletion
                        )
                    )
                }
            }
            #endif
        }
        .toolbar(viewModel.isMangaDirectoryManagementSelectionMode ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isMangaDirectoryManagementSelectionMode && !usesSystemSelectionBottomToolbar {
                SelectionBottomToolbar(
                    actions: MangaDirectoryManagementSelectionActions.delete(
                        selectedCount: viewModel.selectedMangaDirectoryCount,
                        canDelete: viewModel.mangaDirectoryManagementCanDeleteSelected,
                        onDelete: viewModel.requestSelectedMangaDirectoryDeletion
                    )
                )
                .selectionBottomToolbarCapsule()
            }
        }
        .overlay {
            if viewModel.activeAction == .loading || viewModel.activeAction == .clearingMangaDirectory {
                ProgressView(
                    viewModel.activeAction == .clearingMangaDirectory
                        ? L10n.string("common.deleting")
                        : L10n.string("common.loading")
                )
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .sensoryFeedback(.selection, trigger: viewModel.selectedMangaDirectoryIDs)
        .mangaDirectoryManagementAlert(viewModel: viewModel)
    }
}

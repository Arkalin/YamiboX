import SwiftUI
import YamiboXCore

/// Renders the sheet selected by `LocalFavoritesRoutes`, wiring each sheet to
/// the organizer, sync session, and update monitor it operates on.
struct LocalFavoritesSheetContent: View {
    let sheet: LocalFavoritesRoutes.Sheet
    let organizer: FavoriteLibraryOrganizer
    @Bindable var favoriteShare: FavoriteShareFlowModel
    @ObservedObject var remoteSync: FavoriteRemoteSyncSession
    @ObservedObject var updateMonitor: FavoriteUpdateMonitor
    let routes: LocalFavoritesRoutes

    var body: some View {
        switch sheet {
        case let .categoryName(draft):
            LocalFavoriteCategoryNameSheet(
                draft: draft,
                onCancel: {
                    routes.sheet = nil
                },
                onSave: { name in
                    routes.sheet = nil
                    switch draft.mode {
                    case .create:
                        await organizer.createCategory(name: name)
                    case let .rename(categoryID):
                        await organizer.renameCategory(id: categoryID, name: name)
                    }
                }
            )
        case .categoryManagement:
            LocalFavoriteCategoryManagementSheet(organizer: organizer, routes: routes)
        case let .collectionEditor(draft):
            LocalFavoriteCollectionEditorSheet(
                draft: draft,
                onCancel: {
                    routes.sheet = nil
                },
                onSave: { name, color in
                    routes.sheet = nil
                    switch draft.mode {
                    case .create:
                        await organizer.createCollection(name: name, color: color)
                    case .createFromSelection:
                        await organizer.createCollectionFromSelection(name: name, color: color)
                    case let .edit(collectionID):
                        await organizer.updateCollection(id: collectionID, name: name, color: color)
                    }
                }
            )
        case let .tagSelection(draft):
            FavoriteTagPickerView(organizer: organizer, draft: draft)
        case .selectionMove:
            LocalFavoriteSelectionMoveSheet(organizer: organizer, selection: organizer.selection)
        case .filters:
            LocalFavoriteFilterSheet(organizer: organizer, routes: routes)
                .presentationDetents([.medium, .large])
        case .remoteSyncCategory:
            FavoriteRemoteSyncCategorySheet(
                categories: organizer.categories,
                selectedCategoryID: organizer.selectedCategoryID,
                onCancel: {
                    routes.sheet = nil
                },
                onStart: { categoryID in
                    routes.sheet = nil
                    if await remoteSync.start(targetCategoryID: categoryID) != nil {
                        routes.isSyncProgressPushed = true
                    }
                }
            )
        case .updateFilters:
            NavigationStack {
                FavoriteUpdateFilterSheet(
                    fidFilters: updateMonitor.fidFilters,
                    categoryFilters: updateMonitor.categoryFilters,
                    onSetFidEnabled: { fid, enabled in
                        await updateMonitor.setFidFilter(fid, enabled: enabled)
                    },
                    onSetCategoryEnabled: { categoryID, enabled in
                        await updateMonitor.setCategoryFilter(categoryID, enabled: enabled)
                    }
                )
            }
        case .favoriteShareExportSelection:
            FavoriteShareCategorySelectionSheet(
                title: L10n.string("favorites.share.select_title"),
                categories: organizer.categories,
                selectedCategoryIDs: $favoriteShare.exportCategoryIDs,
                confirmTitle: L10n.string("common.next"),
                onCancel: {
                    favoriteShare.cancelExport()
                    routes.sheet = nil
                },
                onConfirm: {
                    if await favoriteShare.prepareExport() {
                        routes.sheet = .favoriteShareExportPreview
                    }
                }
            )
        case .favoriteShareExportPreview:
            if let export = favoriteShare.preparedExport {
                FavoriteShareExportPreviewSheet(
                    export: export,
                    onCancel: {
                        favoriteShare.cancelExport()
                        routes.sheet = nil
                    },
                    onSave: {
                        routes.sheet = nil
                        Task { @MainActor in
                            await Task.yield()
                            favoriteShare.isFileExporterPresented = true
                        }
                    }
                )
            }
        case .favoriteShareImportPreview:
            if let preview = favoriteShare.importPreview {
                FavoriteShareImportPreviewSheet(
                    preview: preview,
                    onCancel: {
                        favoriteShare.cancelImport()
                        routes.sheet = nil
                    },
                    onCreateFolders: {
                        if await favoriteShare.importFavorites(target: .createFolders) {
                            routes.sheet = nil
                        }
                    },
                    onAddToExistingFolders: {
                        favoriteShare.importTargetCategoryIDs = []
                        routes.sheet = .favoriteShareImportTarget
                    }
                )
            }
        case .favoriteShareImportTarget:
            FavoriteShareCategorySelectionSheet(
                title: L10n.string("favorites.share.import_target_title"),
                categories: organizer.categories,
                selectedCategoryIDs: $favoriteShare.importTargetCategoryIDs,
                confirmTitle: L10n.string("favorites.share.import_confirm"),
                onCancel: {
                    favoriteShare.cancelImport()
                    routes.sheet = nil
                },
                onConfirm: {
                    if await favoriteShare.importFavorites(
                        target: .addToExistingFolders(categoryIDs: favoriteShare.importTargetCategoryIDs)
                    ) {
                        routes.sheet = nil
                    }
                }
            )
        }
    }
}

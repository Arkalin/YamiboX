import SwiftUI
import YamiboXCore

/// Renders the sheet selected by `LocalFavoritesRoutes`, wiring each sheet to
/// the organizer, sync session, and update monitor it operates on.
struct LocalFavoritesSheetContent: View {
    let sheet: LocalFavoritesRoutes.Sheet
    let organizer: FavoriteLibraryOrganizer
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
        }
    }
}

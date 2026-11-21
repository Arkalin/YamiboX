import Foundation
import YamiboXCore

@MainActor
final class LocalFavoritesRoutes: ObservableObject {
    enum Sheet: Identifiable {
        case categoryName(LocalFavoriteCategoryNameDraft)
        case categoryManagement
        case collectionEditor(LocalFavoriteCollectionDraft)
        case tagSelection(LocalFavoriteTagSelectionDraft)
        case selectionMove
        case filters
        case remoteSyncCategory
        case updateFilters
        case favoriteShareExportSelection
        case favoriteShareExportPreview
        case favoriteShareImportPreview
        case favoriteShareImportTarget

        var id: String {
            switch self {
            case let .categoryName(draft):
                "categoryName-\(draft.id)"
            case .categoryManagement:
                "categoryManagement"
            case let .collectionEditor(draft):
                "collectionEditor-\(draft.id)"
            case let .tagSelection(draft):
                "tagSelection-\(draft.id)"
            case .selectionMove:
                "selectionMove"
            case .filters:
                "filters"
            case .remoteSyncCategory:
                "remoteSyncCategory"
            case .updateFilters:
                "updateFilters"
            case .favoriteShareExportSelection:
                "favoriteShareExportSelection"
            case .favoriteShareExportPreview:
                "favoriteShareExportPreview"
            case .favoriteShareImportPreview:
                "favoriteShareImportPreview"
            case .favoriteShareImportTarget:
                "favoriteShareImportTarget"
            }
        }
    }

    enum Dialog: Identifiable {
        case dissolveCollection(LocalFavoriteCollection)
        case deleteItem(FavoriteItem)
        case deleteSelection(LocalFavoriteSelectionDeletePlan)
        case dissolveSelectedCollections

        var id: String {
            switch self {
            case let .dissolveCollection(collection):
                "dissolveCollection-\(collection.id)"
            case let .deleteItem(item):
                "deleteItem-\(item.id)"
            case .deleteSelection:
                "deleteSelection"
            case .dissolveSelectedCollections:
                "dissolveSelectedCollections"
            }
        }
    }

    @Published var sheet: Sheet?
    private(set) var dialogIdentity = UUID()
    @Published var dialog: Dialog? {
        didSet { dialogIdentity = UUID() }
    }
    @Published var detail: ContentDetailDestination?
    @Published var isSyncProgressPushed = false
    @Published var isUpdatesPagePushed = false
    @Published var isBoardFavoritesPushed = false
}

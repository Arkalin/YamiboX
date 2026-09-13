import SwiftUI

enum LocalFavoritesDestination: Hashable {
    case collection(String)
    case mergedGroup(String)
    case updates
    case boardFavorites
    case syncProgress
    case detail(ContentDetailDestination)
    case forum(ForumDestination)
}

enum LocalFavoritesSidebarDestination: Hashable {
    case category(String)
    case collection(String)
}

/// Projects the existing browse/presentation state and forum routes into one
/// stack. Popping a detail must not discard the collection beneath it.
@MainActor
struct LocalFavoritesNavigation {
    let organizer: FavoriteLibraryOrganizer
    let routes: LocalFavoritesRoutes
    let navigator: ForumDestinationNavigator

    var path: [LocalFavoritesDestination] {
        get {
            var result: [LocalFavoritesDestination] = []
            if let id = organizer.selectedCollectionID { result.append(.collection(id)) }
            if let name = organizer.selectedMergedGroupCleanBookName { result.append(.mergedGroup(name)) }
            if routes.isUpdatesPagePushed { result.append(.updates) }
            if routes.isBoardFavoritesPushed { result.append(.boardFavorites) }
            if routes.isSyncProgressPushed { result.append(.syncProgress) }
            if let detail = routes.detail { result.append(.detail(detail)) }
            return result + navigator.path.map(LocalFavoritesDestination.forum)
        }
        nonmutating set {
            if let id = organizer.selectedCollectionID, !newValue.contains(.collection(id)) {
                organizer.closeCollection()
            }
            if let name = organizer.selectedMergedGroupCleanBookName, !newValue.contains(.mergedGroup(name)) {
                organizer.closeMergedGroup()
            }
            routes.isUpdatesPagePushed = newValue.contains(.updates)
            routes.isBoardFavoritesPushed = newValue.contains(.boardFavorites)
            routes.isSyncProgressPushed = newValue.contains(.syncProgress)
            routes.detail = newValue.compactMap { destination in
                guard case let .detail(detail) = destination else { return nil }
                return detail
            }.first
            navigator.path = newValue.compactMap { destination in
                guard case let .forum(route) = destination else { return nil }
                return route
            }
        }
    }

    var binding: Binding<[LocalFavoritesDestination]> {
        Binding(get: { path }, set: { path = $0 })
    }

    var sidebarDestination: LocalFavoritesSidebarDestination {
        if let id = organizer.selectedCollectionID {
            .collection(id)
        } else {
            .category(organizer.selectedCategoryID)
        }
    }

    func selectSidebarDestination(_ destination: LocalFavoritesSidebarDestination) {
        guard !organizer.selection.isSelectionMode else { return }
        switch destination {
        case let .category(id):
            guard organizer.categories.contains(where: { $0.id == id }) else { return }
            path = []
            organizer.selectedCategoryID = id
        case let .collection(id):
            guard organizer.collections.contains(where: { $0.id == id }) else { return }
            path = []
            organizer.openCollection(id: id)
        }
    }
}

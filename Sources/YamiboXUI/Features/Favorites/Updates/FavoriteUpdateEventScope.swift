import YamiboXCore

/// One presentation snapshot shared by the favorites bell and updates list.
struct FavoriteUpdateEventScope {
    let events: [FavoriteUpdateEvent]
    let unreadCount: Int

    init(
        items: @autoclosure () -> [FavoriteItem],
        events: [FavoriteUpdateEvent],
        fidFilters: [FavoriteUpdateFidFilter],
        categoryFilters: [FavoriteUpdateCategoryFilter],
        trackedTargets: @autoclosure () -> [FavoriteUpdateTrackedTarget]
    ) {
        let disabledFidsExist = fidFilters.contains { !$0.enabled }
        let disabledCategoriesExist = categoryFilters.contains { !$0.enabled }
        var enabledFids: [String: Bool] = [:]
        if disabledFidsExist {
            for filter in fidFilters where enabledFids[filter.fid] == nil {
                enabledFids[filter.fid] = filter.enabled
            }
        }

        var favoriteCategories: [String: Set<String>] = [:]
        var directoryCategories: [FavoriteUpdateTargetKey: Set<String>] = [:]
        var enabledCategoryIDs: Set<String> = []
        if disabledCategoriesExist && !events.isEmpty {
            // Keep the first matching item/target, including an empty category set.
            for item in items() where favoriteCategories[item.target.id] == nil {
                favoriteCategories[item.target.id] = Set(item.locations.compactMap(\.categoryID))
            }
            for target in trackedTargets() where directoryCategories[target.target] == nil {
                directoryCategories[target.target] = target.categoryIDs
            }
            enabledCategoryIDs = Set(categoryFilters.filter(\.enabled).map(\.categoryID))
        }

        self.events = events.filter { event in
            if disabledFidsExist, let fid = event.fid, enabledFids[fid] == false {
                return false
            }
            guard disabledCategoriesExist else { return true }
            let categories: Set<String>
            switch event.target {
            case .favorite:
                categories = favoriteCategories[event.target.id] ?? []
            case .mangaDirectory:
                categories = directoryCategories[event.target] ?? []
            }
            return categories.isEmpty || !categories.isDisjoint(with: enabledCategoryIDs)
        }
        unreadCount = self.events.reduce(into: 0) { count, event in
            if event.readAt == nil { count += 1 }
        }
    }
}

@MainActor
final class FavoriteUpdateEventScopeCache {
    struct Revision: Equatable {
        let organizer: ObjectIdentifier
        let monitor: ObjectIdentifier
        let items: UInt64
        let events: UInt64
        let scope: UInt64
    }

    private var revision: Revision?
    private var cached: FavoriteUpdateEventScope?

    func value(
        revision: Revision,
        items: @autoclosure () -> [FavoriteItem],
        events: @autoclosure () -> [FavoriteUpdateEvent],
        fidFilters: @autoclosure () -> [FavoriteUpdateFidFilter],
        categoryFilters: @autoclosure () -> [FavoriteUpdateCategoryFilter],
        trackedTargets: @autoclosure () -> [FavoriteUpdateTrackedTarget]
    ) -> FavoriteUpdateEventScope {
        if self.revision == revision, let cached { return cached }
        let result = FavoriteUpdateEventScope(
            items: items(), events: events(), fidFilters: fidFilters(),
            categoryFilters: categoryFilters(), trackedTargets: trackedTargets()
        )
        self.revision = revision
        cached = result
        return result
    }
}

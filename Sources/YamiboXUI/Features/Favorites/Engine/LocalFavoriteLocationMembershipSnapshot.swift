import YamiboXCore

/// Tri-state per-item location membership (all / some / none of the selected
/// items carry a location).
enum LocalFavoriteLocationTriState: Equatable, Sendable {
    case none
    case some
    case all
}

/// Display-only membership counts, prepared once instead of scanning the
/// selected items again for every category and collection row.
struct LocalFavoriteLocationMembershipSnapshot: Equatable, Sendable {
    let itemCount: Int
    private let memberCount: Int
    private let counts: [FavoriteLocation: Int]

    init(items: [FavoriteItem], displayedItemCount: Int? = nil) {
        itemCount = displayedItemCount ?? items.count
        memberCount = items.count
        var counts: [FavoriteLocation: Int] = [:]
        for item in items {
            // Codable can retain repeated locations. A row's original
            // `contains` predicate counted each item only once per location.
            for location in Set(item.locations) {
                counts[location, default: 0] += 1
            }
        }
        self.counts = counts
    }

    func state(_ location: FavoriteLocation) -> LocalFavoriteLocationTriState {
        let count = counts[location, default: 0]
        if count == 0 { return .none }
        return count == memberCount ? .all : .some
    }
}

import YamiboXCore

/// A nonoptional navigation selection keeps All highlighted in the sidebar.
enum BrowsingHistoryFilter: String, CaseIterable, Hashable {
    case all
    case normal
    case novel
    case manga

    init(category: BrowsingHistoryCategory?) {
        switch category {
        case nil: self = .all
        case .normal: self = .normal
        case .novel: self = .novel
        case .manga: self = .manga
        }
    }

    var category: BrowsingHistoryCategory? {
        switch self {
        case .all: nil
        case .normal: .normal
        case .novel: .novel
        case .manga: .manga
        }
    }

    var title: String {
        L10n.string("history.filter.\(rawValue)")
    }

    var systemImage: String {
        switch self {
        case .all: "clock"
        case .normal: "text.bubble"
        case .novel: "book"
        case .manga: "photo.on.rectangle"
        }
    }
}

extension BrowsingHistoryViewModel {
    var availableFilters: [BrowsingHistoryFilter] {
        showsPreviousReading ? [.all, .novel, .manga] : BrowsingHistoryFilter.allCases
    }

    var selectedFilter: BrowsingHistoryFilter {
        get { BrowsingHistoryFilter(category: selectedCategory) }
        set {
            guard availableFilters.contains(newValue) else { return }
            selectedCategory = newValue.category
        }
    }
}

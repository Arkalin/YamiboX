import Foundation
import YamiboXCore

enum FavoriteLaunchMode: Sendable {
    case preferred
    case start
    case resume
}

enum FavoriteMangaReadingScope: Sendable {
    case boardDefault
    case singleThread
}

func favoriteLaunchNeedsMangaProbeBlocker(_ favorite: Favorite) -> Bool {
    false
}

func shouldBlockFavoriteInteractions(openingMangaFavoriteID: String?) -> Bool {
    openingMangaFavoriteID != nil
}

enum FavoriteTagSortOrder: String, CaseIterable, Identifiable {
    case manual
    case name
    case nameDescending
    case updatedAt
    case updatedAtDescending
    case associationCount
    case associationCountDescending

    var id: String { rawValue }

    var usesAssociationCounts: Bool {
        self == .associationCount || self == .associationCountDescending
    }
}

struct FavoriteTagEditorDraft: Identifiable {
    let tag: FavoriteTag?
    var name: String
    var color: FavoriteTagColor

    var id: String { tag?.id ?? "new" }

    init(tag: FavoriteTag?, defaultColor: FavoriteTagColor) {
        self.tag = tag
        name = tag?.name ?? ""
        color = tag?.color ?? defaultColor
    }
}

func filteredFavoriteTags(_ tags: [FavoriteTag], searchText: String) -> [FavoriteTag] {
    let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedSearchText.isEmpty else { return tags }

    return tags.filter { tag in
        tag.name.localizedCaseInsensitiveContains(trimmedSearchText)
    }
}

func canReorderFavoriteTags(sortOrder: FavoriteTagSortOrder, searchText: String) -> Bool {
    sortOrder == .manual && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func sortedFavoriteTags(
    _ tags: [FavoriteTag],
    associationCounts: [String: Int],
    sortOrder: FavoriteTagSortOrder
) -> [FavoriteTag] {
    return tags.sorted { lhs, rhs in
        switch sortOrder {
        case .manual:
            break
        case .name:
            let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if result != .orderedSame {
                return result == .orderedAscending
            }
        case .nameDescending:
            let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if result != .orderedSame {
                return result == .orderedDescending
            }
        case .updatedAt:
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
        case .updatedAtDescending:
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
        case .associationCount:
            let lhsCount = associationCounts[lhs.id, default: 0]
            let rhsCount = associationCounts[rhs.id, default: 0]
            if lhsCount != rhsCount {
                return lhsCount < rhsCount
            }
        case .associationCountDescending:
            let lhsCount = associationCounts[lhs.id, default: 0]
            let rhsCount = associationCounts[rhs.id, default: 0]
            if lhsCount != rhsCount {
                return lhsCount > rhsCount
            }
        }

        if lhs.manualOrder != rhs.manualOrder {
            return lhs.manualOrder < rhs.manualOrder
        }
        return lhs.id < rhs.id
    }
}

func tagAssociationCounts(from favorites: [FavoriteItem]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for favorite in favorites {
        for tagID in Set(favorite.tagIDs) {
            counts[tagID, default: 0] += 1
        }
    }
    return counts
}

import Foundation
import YamiboXCore

enum FavoriteLaunchMode: Sendable {
    case start
    case resume
}

/// How a `.mangaThread` favorite chooses between Smart Comic Mode's
/// merged-directory reading and plain single-thread reading when opened.
/// Orthogonal to `FavoriteLaunchMode` (resume/start applies to either scope).
enum FavoriteMangaReadingScope: Sendable {
    /// Follow the favorite's board switch: merged-directory reading when
    /// Smart Comic Mode is on, single-thread reading when it's off.
    case boardDefault
    /// Force plain single-thread reading regardless of the board switch.
    /// The "查看归档收藏" archive page opens its members this way: the page
    /// deliberately surfaces each archived favorite as an ordinary
    /// non-smart card (see `LocalFavoriteLibraryProjection.cards(in:query:...)`'s
    /// member-scope branch), so tapping one must read exactly that thread —
    /// opening via the board switch instead would bounce every member back
    /// into the same merged directory, making the per-member entries
    /// indistinguishable.
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
    favorites: [FavoriteItem],
    sortOrder: FavoriteTagSortOrder
) -> [FavoriteTag] {
    let associationCounts = tagAssociationCounts(from: favorites)
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

private func tagAssociationCounts(from favorites: [FavoriteItem]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for favorite in favorites {
        for tagID in Set(favorite.tagIDs) {
            counts[tagID, default: 0] += 1
        }
    }
    return counts
}

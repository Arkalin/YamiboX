import SwiftUI
import YamiboXCore

/// One event can appear in several locations, but is acknowledged only once.
struct FavoriteUnreadIndex {
    var favorites: [String: Set<String>] = [:]
    var collections: [String: Set<String>] = [:]

    init() {}

    init(items: [FavoriteItem], directories: [String: MangaDirectory], events: [FavoriteUpdateEvent]) {
        let byTarget = Dictionary(grouping: events.filter {
            $0.readAt == nil && $0.dismissedAt == nil
        }, by: \.target)
        for item in items {
            var ids = Set((byTarget[.favorite(item.target)] ?? []).map(\.id))
            if item.target.kind == .mangaThread,
               let tid = item.target.threadID, let directory = directories[tid] {
                ids.formUnion((byTarget[.mangaDirectory(directoryID: directory.id)] ?? []).map(\.id))
            }
            favorites[item.id] = ids
            for location in item.locations {
                if let collectionID = location.collectionID {
                    collections[collectionID, default: []].formUnion(ids)
                }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var favoriteUnreadIndex = FavoriteUnreadIndex()
}

private struct FavoriteUpdateIndicator: ViewModifier {
    @Environment(\.favoriteUnreadIndex) private var unread
    let id: String
    let isCollection: Bool

    func body(content: Content) -> some View {
        let hasUpdates = !(isCollection ? unread.collections[id, default: []] : unread.favorites[id, default: []]).isEmpty
        content
            .overlay(alignment: .topLeading) {
                if hasUpdates {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                        .padding(3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(hasUpdates ? L10n.string("favorites.updates.unread_indicator") : "")
    }
}

extension View {
    func favoriteUpdateIndicator(id: String, isCollection: Bool = false) -> some View {
        modifier(FavoriteUpdateIndicator(id: id, isCollection: isCollection))
    }
}

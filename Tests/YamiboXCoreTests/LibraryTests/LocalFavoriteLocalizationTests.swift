import Testing
@testable import YamiboXCore

@Test func localFavoriteCriticalLocalizationKeysResolveToDisplayText() {
    let plainKeys = [
        "favorites.title",
        "favorites.search",
        "favorites.default_category",
        "favorites.source_group",
        "favorites.layout",
        "favorites.layout.fixed_grid",
        "favorites.layout.staggered",
        "favorites.layout.row_card",
        "favorites.layout.row_card_text",
        "favorites.sort",
        "favorites.sort.descending",
        "favorites.sort.manual",
        "favorites.sort.updated_at",
        "favorites.sort.remote_order",
        "favorites.sort.title",
        "favorites.sort.recent_read",
        "favorites.category.create",
        "favorites.category.manage",
        "favorites.collections",
        "favorites.sync.progress.title",
        "favorites.updates.title"
    ]

    for key in plainKeys {
        #expect(L10n.string(key) != key)
    }
    #expect(L10n.string("favorites.items_count", 3) != "favorites.items_count")
}

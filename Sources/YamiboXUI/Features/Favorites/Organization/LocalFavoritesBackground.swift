import SwiftUI
import YamiboXCore

/// Wraps a favorites page's content in `FavoriteBackgroundLayer`. Applied at
/// every page `LocalFavoritesOrganizationView` owns — the root screen plus
/// the pushed collection-detail and merged-group ("查看归档收藏") detail pages
/// — so navigating deeper keeps the background the user picked instead of
/// falling back to the system default. Each page draws its own layer rather
/// than sharing one behind the whole `NavigationStack`, because a pushed
/// destination renders over its own opaque backdrop.
struct LocalFavoritesBackground<Content: View>: View {
    let settings: FavoriteBackgroundSettings
    let imageData: Data?
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            FavoriteBackgroundLayer(settings: settings, imageData: imageData)
                .ignoresSafeArea()
            content
        }
    }
}

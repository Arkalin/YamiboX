import SwiftUI
import YamiboXCore

/// Wraps the root favorites screen's content in `FavoriteBackgroundLayer`.
/// Deliberately used only at `LocalFavoritesOrganizationView`'s root call
/// site — the pushed collection-detail and merged-group-detail pages keep
/// the system default background.
struct LocalFavoritesRootBackground<Content: View>: View {
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

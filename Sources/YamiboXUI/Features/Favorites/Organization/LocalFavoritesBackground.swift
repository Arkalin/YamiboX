import SwiftUI
import YamiboXCore

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

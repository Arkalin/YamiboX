import SwiftUI
import YamiboXCore

struct FavoriteBackgroundLayer: View {
    let settings: FavoriteBackgroundSettings
    let imageData: Data?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            if settings.isEnabled,
               let imageData,
               CustomBackgroundImageDecodeCache.shared.image(for: imageData) != nil {
                ZStack {
                    CustomBackgroundLayer(settings: settings, imageData: imageData)

                    readabilityOverlay
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private var readabilityOverlay: Color {
        colorScheme == .dark ? Color.black.opacity(0.32) : Color.white.opacity(0.28)
    }

}

import SwiftUI
import YamiboXCore

struct CustomBackgroundLayer: View {
    let settings: CustomBackgroundSettings
    let imageData: Data?

    var body: some View {
        GeometryReader { geometry in
            if settings.isEnabled, let imageData,
               let image = CustomBackgroundImageDecodeCache.shared.image(for: imageData) {
                let frame = CustomBackgroundLayout.renderedFrame(
                    imageSize: image.size, containerSize: geometry.size, settings: settings
                )
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frame.size.width, height: frame.size.height)
                    .offset(frame.offset)
                    .blur(radius: settings.blurRadius)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

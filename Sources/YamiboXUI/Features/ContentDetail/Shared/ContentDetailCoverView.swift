import SwiftUI
import YamiboXCore

/// Remote book artwork with a shared text fallback and a stable aspect ratio.
struct ContentDetailCoverView: View {
    @Environment(\.forumTheme) private var theme
    @Namespace private var imageBrowserZoomNamespace
    @State private var imageBrowserItem: ImageBrowserItem?
    let source: YamiboImageSource?
    let title: String
    var width: CGFloat = 86

    var body: some View {
        ZStack {
            if let source {
                YamiboRemoteImage(source: source) { image in
                    Button {
                        imageBrowserItem = ImageBrowserItem(id: source.cacheKey, source: source, title: title)
                    } label: {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: width * 112 / 86)
                            .background(theme.mutedAccent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .imageBrowserZoomSource(id: source.cacheKey, in: imageBrowserZoomNamespace)
                    .accessibilityLabel(L10n.string("cover.view"))
                    .accessibilityValue(title)
                } placeholder: {
                    placeholder
                } failure: {
                    placeholder
                }
                .id(source.cacheKey)
            } else {
                placeholder
            }
        }
        .frame(width: width, height: width * 112 / 86)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.border.opacity(0.7), lineWidth: 1)
        }
        .fullScreenCover(item: $imageBrowserItem) { item in
            ImageBrowserView(
                items: [item],
                initialItemID: item.id,
                mode: .single,
                presentation: .zoom(imageBrowserZoomNamespace),
                onDismiss: { imageBrowserItem = nil }
            )
        }
    }

    private var placeholder: some View {
        BookCoverTextFallback(title: title, boxWidth: width)
            .frame(width: width, height: width * 112 / 86)
            .accessibilityHidden(true)
    }
}

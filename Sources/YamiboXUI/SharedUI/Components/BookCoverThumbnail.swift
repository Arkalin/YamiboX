import SwiftUI
import YamiboXCore

/// Cover with a text placeholder: when there is no cover URL or it fails to
/// load, the full title renders bold over a tinted background, its font size
/// stepped down by title length (Android CoverTextFallback parity).
///
/// Sizing goes through a `GeometryReader` rather than
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)`: inside a List row
/// whose tap target is a `Button` label, that greedy frame style can resolve
/// against the button's ideal-size measurement pass instead of the final
/// layout size, letting the cover balloon past its intended box (real images
/// bleeding outside their frame; the text fallback stretching to the row's
/// full width). `GeometryReader` always reports the size it was actually
/// proposed, so the explicit `.frame(width:height:)` callers apply is honored
/// exactly.
struct BookCoverThumbnail: View {
    let url: URL?
    let title: String
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let url, let thumbnail = YamiboImageThumbnail(pointSize: proxy.size, displayScale: displayScale) {
                    YamiboRemoteImage(source: YamiboImageSource(url: url), thumbnail: thumbnail) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } placeholder: {
                        textFallback(in: proxy.size)
                    } failure: {
                        textFallback(in: proxy.size)
                    }
                } else {
                    textFallback(in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private func textFallback(in size: CGSize) -> some View {
        BookCoverTextFallback(title: title, boxWidth: size.width)
            .frame(width: size.width, height: size.height)
    }
}

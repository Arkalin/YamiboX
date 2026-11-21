import SwiftUI
import YamiboXCore

struct BookCoverThumbnail: View {
    let source: YamiboImageSource?
    let title: String
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let source, let thumbnail = YamiboImageThumbnail(pointSize: proxy.size, displayScale: displayScale) {
                    YamiboRemoteImage(source: source, thumbnail: thumbnail) { image in
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

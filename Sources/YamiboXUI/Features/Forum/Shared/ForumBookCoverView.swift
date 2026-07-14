import SwiftUI
import YamiboXCore

/// The 86×112 book cover used by the manga/novel detail headers: brown
/// wash under a remote image, glyph fallback, hairline border.
struct ForumBookCoverView: View {
    let source: YamiboImageSource?
    var placeholderSystemImage = "book.closed"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ForumColors.brownPrimary.opacity(0.12))

            if let source {
                YamiboRemoteImage(source: source) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ForumColors.brownPrimary)
                } failure: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 86, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ForumColors.border.opacity(0.7), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: placeholderSystemImage)
            .font(.title2)
            .foregroundStyle(ForumColors.brownPrimary.opacity(0.55))
    }
}

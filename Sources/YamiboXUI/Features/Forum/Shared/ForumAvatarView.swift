import SwiftUI
import YamiboXCore

/// Circular remote avatar with the person-glyph fallback. `placeholderFont`
/// scales the fallback glyph for larger avatar sizes; nil inherits the
/// ambient font like the original inline implementations did.
struct ForumAvatarView: View {
    let url: URL?
    let size: CGFloat
    var placeholderSystemImage = "person.crop.circle"
    var placeholderFont: Font? = nil

    var body: some View {
        YamiboRemoteImage(source: url.map { YamiboImageSource(url: $0) }) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            placeholder
        } failure: {
            placeholder
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Image(systemName: placeholderSystemImage)
            .font(placeholderFont)
            .foregroundStyle(ForumColors.secondaryText)
    }
}

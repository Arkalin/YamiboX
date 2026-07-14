import SwiftUI
import YamiboXCore

struct ForumThreadImageBlockView: View {
    let blockID: String
    let block: ForumThreadImageBlock
    let refererURL: URL
    let onImageTap: (String, URL, String?, URL) -> Void
    let onURLTap: (URL) -> Void

    @Environment(\.imageBrowserZoomNamespace) private var imageBrowserZoomNamespace

    var body: some View {
        if block.isEmoticon {
            image
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(block.altText ?? L10n.string("forum.thread.image"))
        } else {
            Button {
                if let linkURL = block.linkURL {
                    onURLTap(linkURL)
                } else {
                    onImageTap(blockID, block.url, block.altText, refererURL)
                }
            } label: {
                image
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .imageBrowserZoomSource(id: blockID, in: block.linkURL == nil ? imageBrowserZoomNamespace : nil)
            .accessibilityLabel(block.altText ?? L10n.string("forum.thread.image"))
        }
    }

    private var image: some View {
        YamiboRemoteImage(
            source: YamiboImageSource(url: block.url, refererPageURL: refererURL)
        ) { image in
            image
                .resizable()
                .scaledToFit()
        } placeholder: {
            ForumThreadImagePlaceholderView()
        } failure: {
            ForumThreadImageFailureView()
        }
    }
}

private struct ForumThreadImagePlaceholderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(ForumColors.creamBackground)
            .frame(height: 180)
            .overlay {
                ProgressView()
            }
    }
}

private struct ForumThreadImageFailureView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(ForumColors.creamBackground)
            .frame(height: 120)
            .overlay {
                Label(L10n.string("forum.thread.image_load_failed"), systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(ForumColors.secondaryText)
            }
    }
}

import SwiftUI
import YamiboXCore

struct ForumThreadImageBlockView: View {
    @Environment(\.forumTheme) private var theme
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
            image
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .imageBrowserZoomSource(id: blockID, in: block.linkURL == nil ? imageBrowserZoomNamespace : nil)
        }
    }

    /// Posts are full of animated smileys and GIFs, so thread content plays
    /// them rather than freezing on the first frame.
    private var image: some View {
        YamiboRemoteImage(
            source: YamiboImageSource(url: block.url, refererPageURL: refererURL),
            animates: true
        ) { image in
            imageAction {
                ForumThreadImageContentView(
                    image: image,
                    maxDimension: block.isEmoticon ? 40 : 520
                )
            }
        } placeholder: {
            imageAction { ForumThreadImagePlaceholderView() }
        } retryableFailure: { retry in
            ForumThreadImageFailureView(
                isEmoticon: block.isEmoticon,
                retry: retry,
                open: openImage
            )
        }
    }

    @ViewBuilder
    private func imageAction<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if block.isEmoticon {
            content()
        } else {
            Button(action: openImage, label: content)
                .buttonStyle(.plain)
                .accessibilityLabel(block.altText ?? L10n.string("forum.thread.image"))
        }
    }

    private func openImage() {
        if let linkURL = block.linkURL {
            onURLTap(linkURL)
        } else {
            onImageTap(blockID, block.url, block.altText, refererURL)
        }
    }
}

private struct ForumThreadImageContentView: View {
    @Environment(\.forumTheme) private var theme
    let image: Image
    let maxDimension: CGFloat

    @Environment(\.yamiboRemoteImageSize) private var remoteImageSize

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: maxImageWidth, maxHeight: maxDimension, alignment: .leading)
    }

    private var maxImageWidth: CGFloat {
        ForumThreadImageDisplaySizing.maxWidth(
            for: remoteImageSize,
            maxDimension: maxDimension
        )
    }
}

enum ForumThreadImageDisplaySizing {
    static let defaultMaxDimension: CGFloat = 520

    static func maxWidth(
        for imageSize: CGSize?,
        maxDimension: CGFloat = defaultMaxDimension
    ) -> CGFloat {
        guard let width = imageSize?.width,
              width.isFinite,
              width > 0 else {
            return maxDimension
        }
        return min(width, maxDimension)
    }
}

private struct ForumThreadImagePlaceholderView: View {
    @Environment(\.forumTheme) private var theme
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.pageBackground)
            .frame(height: 180)
            .overlay {
                ProgressView()
            }
    }
}

private struct ForumThreadImageFailureView: View {
    @Environment(\.forumTheme) private var theme
    let isEmoticon: Bool
    let retry: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if !isEmoticon {
                Button(action: open) {
                    failureLabel
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            Button(action: retry) {
                Label(L10n.string("common.retry"), systemImage: "arrow.clockwise")
                    .frame(minHeight: isEmoticon ? 40 : 44)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("forum-thread-image-retry")
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .frame(minHeight: isEmoticon ? 40 : 120)
        .background(theme.pageBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var failureLabel: some View {
        Label(L10n.string("forum.thread.image_load_failed"), systemImage: "photo")
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
    }
}

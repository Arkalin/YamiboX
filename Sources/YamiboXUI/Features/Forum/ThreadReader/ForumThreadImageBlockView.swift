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
                .frame(maxHeight: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(block.altText ?? L10n.string("forum.thread.image"))
        } else {
            image
                .frame(maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    authoredWidth: block.width,
                    authoredHeight: block.height,
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
    let authoredWidth: Double?
    let authoredHeight: Double?
    let maxDimension: CGFloat

    @Environment(\.yamiboRemoteImageSize) private var remoteImageSize

    var body: some View {
        image
            .resizable()
            .aspectRatio(displaySize.map { $0.width / max($0.height, 1) }, contentMode: .fit)
            .frame(maxWidth: maxImageWidth, maxHeight: maxDimension, alignment: .leading)
    }

    private var maxImageWidth: CGFloat {
        ForumThreadImageDisplaySizing.maxWidth(
            for: displaySize,
            maxDimension: maxDimension
        )
    }

    private var displaySize: CGSize? {
        let ratio = (remoteImageSize?.width ?? 1) / max(remoteImageSize?.height ?? 1, 1)
        switch (authoredWidth, authoredHeight) {
        case let (width?, height?): return CGSize(width: width, height: height)
        case let (width?, nil): return CGSize(width: width, height: width / ratio)
        case let (nil, height?): return CGSize(width: height * ratio, height: height)
        case (nil, nil): return remoteImageSize
        }
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
        let height = imageSize?.height ?? 0
        return min(width, maxDimension, height > maxDimension ? width * maxDimension / height : width)
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

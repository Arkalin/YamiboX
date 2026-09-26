import SwiftUI
import YamiboXCore

struct ForumThreadTextBlockView: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let block: ForumThreadTextBlock
    var refererURL: URL = YamiboDomain.baseURL
    let onURLTap: (URL) -> Void

    @State private var cache = ForumThreadTextBlockFormatterCache()

    @ViewBuilder
    var body: some View {
        if block.rubies.isEmpty, block.paragraphStyle == nil {
            plainText
        } else {
            ForumThreadRichTextBlockView(
                block: block,
                refererURL: refererURL,
                onURLTap: onURLTap
            )
        }
    }

    private var plainText: some View {
        ForumThreadInlineTextView(attributedText: cache.attributedText(for: block, theme: theme, dynamicTypeSize: dynamicTypeSize), refererURL: refererURL)
            .font(.body)
            .lineSpacing(4)
            .foregroundStyle(theme.primaryText)
            .multilineTextAlignment(block.alignment.swiftUITextAlignment)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: block.alignment.swiftUIFrameAlignment)
            .environment(\.openURL, OpenURLAction { url in
                onURLTap(url)
                return .handled
            })
    }
}

extension ForumThreadTextAlignment {
    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .center:
            return .center
        case .right:
            return .trailing
        case .start, .left:
            return .leading
        }
    }

    var swiftUIFrameAlignment: Alignment {
        switch self {
        case .center:
            return .center
        case .right:
            return .trailing
        case .start, .left:
            return .leading
        }
    }
}

import SwiftUI
import YamiboXCore

struct ForumThreadTextBlockView: View {
    let block: ForumThreadTextBlock
    let onURLTap: (URL) -> Void

    @State private var cache = ForumThreadTextBlockFormatterCache()

    @ViewBuilder
    var body: some View {
        if block.rubies.isEmpty {
            plainText
        } else {
            ForumThreadRubyTextBlockView(
                segments: cache.rubySegments(for: block),
                alignment: block.alignment,
                onURLTap: onURLTap
            )
        }
    }

    private var plainText: some View {
        Text(cache.attributedText(for: block))
            .font(.body)
            .lineSpacing(4)
            .foregroundStyle(ForumColors.textDark)
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

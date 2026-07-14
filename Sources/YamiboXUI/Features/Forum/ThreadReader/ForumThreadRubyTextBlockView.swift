import SwiftUI
import YamiboXCore

struct ForumThreadRubySegment: Identifiable {
    var id = UUID()
    var attributedText: AttributedString
    var rubyText: String?
}

struct ForumThreadRubyTextBlockView: View {
    let segments: [ForumThreadRubySegment]
    let alignment: ForumThreadTextAlignment
    let onURLTap: (URL) -> Void

    var body: some View {
        ForumThreadRubyFlowLayout(alignment: alignment) {
            ForEach(segments) { segment in
                ForumThreadRubySegmentView(segment: segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment.swiftUIFrameAlignment)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            onURLTap(url)
            return .handled
        })
    }
}

private struct ForumThreadRubySegmentView: View {
    let segment: ForumThreadRubySegment

    var body: some View {
        if let rubyText = segment.rubyText {
            VStack(spacing: 0) {
                Text(rubyText)
                    .font(.caption2)
                    .foregroundStyle(ForumColors.secondaryText)
                    .lineLimit(1)
                Text(segment.attributedText)
                    .font(.body)
                    .foregroundStyle(ForumColors.textDark)
                    .lineLimit(1)
            }
        } else {
            Text(segment.attributedText)
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(ForumColors.textDark)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct ForumThreadRubyFlowLayout: Layout {
    var alignment: ForumThreadTextAlignment

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? subviews.reduce(CGFloat.zero) { partial, subview in
            partial + subview.sizeThatFits(.unspecified).width
        }
        let lines = measuredLines(maxWidth: max(maxWidth, 1), subviews: subviews)
        return CGSize(
            width: maxWidth,
            height: lines.reduce(CGFloat.zero) { partial, line in
                partial + line.height
            }
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let lines = measuredLines(maxWidth: max(bounds.width, 1), subviews: subviews)
        var y = bounds.minY
        var index = 0
        for line in lines {
            var x = bounds.minX + horizontalOffset(for: line.width, in: bounds.width)
            for size in line.sizes {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height)),
                    proposal: ProposedViewSize(size)
                )
                x += size.width
                index += 1
            }
            y += line.height
        }
    }

    private func measuredLines(maxWidth: CGFloat, subviews: Subviews) -> [ForumThreadRubyFlowLine] {
        var lines: [ForumThreadRubyFlowLine] = []
        var currentSizes: [CGSize] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        func flush() {
            guard !currentSizes.isEmpty else { return }
            lines.append(
                ForumThreadRubyFlowLine(
                    sizes: currentSizes,
                    width: currentWidth,
                    height: currentHeight
                )
            )
            currentSizes = []
            currentWidth = 0
            currentHeight = 0
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth > 0, currentWidth + size.width > maxWidth {
                flush()
            }
            currentSizes.append(size)
            currentWidth += size.width
            currentHeight = max(currentHeight, size.height)
        }
        flush()
        return lines
    }

    private func horizontalOffset(for lineWidth: CGFloat, in availableWidth: CGFloat) -> CGFloat {
        switch alignment {
        case .center:
            return max((availableWidth - lineWidth) / 2, 0)
        case .right:
            return max(availableWidth - lineWidth, 0)
        case .start, .left:
            return 0
        }
    }
}

private struct ForumThreadRubyFlowLine {
    var sizes: [CGSize]
    var width: CGFloat
    var height: CGFloat
}

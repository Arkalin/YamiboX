import SwiftUI
import YamiboXCore

struct ContentDetailHeader<Metadata: View, Actions: View, Details: View>: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDetails = false

    let title: String
    let coverSource: YamiboImageSource?
    let onCopyText: ((String) -> Void)?
    @ViewBuilder let metadata: (_ compact: Bool) -> Metadata
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let details: () -> Details

    var body: some View {
        let compact = verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ContentDetailCoverView(source: coverSource, title: title, width: compact ? 80 : 104)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 0) {
                        Text(title)
                            .font(compact ? .headline : .title3.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contextMenu {
                                Button {
                                    showsDetails = true
                                } label: {
                                    Label(L10n.string("forum.detail.info"), systemImage: "info.circle")
                                }
                                if let onCopyText {
                                    Button {
                                        onCopyText(title)
                                    } label: {
                                        Label(L10n.string("reader.copy"), systemImage: "doc.on.doc")
                                    }
                                }
                            }

                        Button {
                            showsDetails = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.body)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityLabel(L10n.string("forum.detail.info"))
                        .help(L10n.string("forum.detail.info"))
                    }

                    metadata(compact)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            actions()
        }
        // Keep a usable directory viewport at accessibility sizes. The details
        // sheet retains the user's uncapped text size and all metadata.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: 0.5)
        }
        .accessibilityIdentifier("forum.detail.header")
        .sheet(isPresented: $showsDetails) {
            ContentDetailInformationSheet(title: title, onCopyText: onCopyText, content: details)
                .environment(\.forumTheme, theme)
                .presentationDetents([.medium, .large])
        }
    }
}

struct ContentDetailInformationSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forumTheme) private var theme
    let title: String
    let onCopyText: ((String) -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .contextMenu {
                            if let onCopyText {
                                Button {
                                    onCopyText(title)
                                } label: {
                                    Label(L10n.string("reader.copy"), systemImage: "doc.on.doc")
                                }
                            }
                        }
                    content()
                }
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .forumPageBackground()
            .navigationTitle(L10n.string("forum.detail.info"))
            .yamiboInlineNavigationTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done")) { dismiss() }
                }
            }
        }
        .tint(theme.accentText)
    }
}

/// Wrap actions using their intrinsic widths instead of compressing their
/// labels or duplicating interactive controls in ViewThatFits alternatives.
struct ContentDetailActionsLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(for: subviews, width: proposal.width)
        let width = proposal.width ?? sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: width, height: positions(sizes: sizes, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(for: subviews, width: bounds.width)
        let layout = positions(sizes: sizes, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + layout.origins[index].x, y: bounds.minY + layout.origins[index].y),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func sizes(for subviews: Subviews, width: CGFloat?) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return subview.sizeThatFits(ProposedViewSize(width: min(width ?? ideal.width, ideal.width), height: nil))
        }
    }

    private func positions(sizes: [CGSize], width: CGFloat) -> (origins: [CGPoint], height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, y + rowHeight)
    }
}

struct ContentDetailPrimaryActions<Content: View>: View {
    @ScaledMetric(relativeTo: .subheadline) private var minimumReadingWidth: CGFloat = 144
    @ViewBuilder let content: () -> Content

    var body: some View {
        ContentDetailPrimaryActionsLayout(minimumReadingWidth: minimumReadingWidth) {
            content()
        }
    }
}

/// The first action expands; secondary actions keep their labels intact. Measure
/// the primary at its allocated width so long progress never dictates wrapping.
struct ContentDetailPrimaryActionsLayout: Layout {
    var minimumReadingWidth: CGFloat = 144
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 358
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard let primary = subviews.first else { return [] }
        let secondarySizes = subviews.dropFirst().map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return subview.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
        }
        let secondaryWidth = secondarySizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(secondarySizes.count)
        let inline = secondarySizes.isEmpty || width - secondaryWidth >= minimumReadingWidth
        let primaryWidth = inline ? width - secondaryWidth : width
        let primarySize = primary.sizeThatFits(ProposedViewSize(width: primaryWidth, height: nil))
        let rowHeight = inline ? max(primarySize.height, secondarySizes.map(\.height).max() ?? 0) : primarySize.height
        var frames = [CGRect(x: 0, y: 0, width: primaryWidth, height: rowHeight)]
        if inline {
            var x = primaryWidth + spacing
            for size in secondarySizes {
                frames.append(CGRect(x: x, y: 0, width: size.width, height: rowHeight))
                x += size.width + spacing
            }
        } else {
            var row: [CGSize] = []
            var rowWidth: CGFloat = 0
            var y = rowHeight + spacing
            func appendRow() {
                let height = row.map(\.height).max() ?? 0
                var x = width - rowWidth
                for size in row {
                    frames.append(CGRect(x: x, y: y, width: size.width, height: height))
                    x += size.width + spacing
                }
                y += height + spacing
            }
            for size in secondarySizes {
                if !row.isEmpty, rowWidth + spacing + size.width > width {
                    appendRow()
                    row = []
                    rowWidth = 0
                }
                rowWidth += (row.isEmpty ? 0 : spacing) + size.width
                row.append(size)
            }
            if !row.isEmpty { appendRow() }
        }
        return frames
    }
}

struct ContentDetailReadButton: View {
    @Environment(\.forumTheme) private var theme
    let hasProgress: Bool
    var isEnabled = true
    var progressText: String? = nil
    let action: () -> Void

    private var progressSummary: String? {
        guard hasProgress, let progressText, !progressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return progressText
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(
                    L10n.string(hasProgress ? "forum.thread_route.continue_novel" : "forum.thread_route.read_novel"),
                    systemImage: "book"
                )
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                if let progressSummary {
                    Text(progressSummary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: .infinity, alignment: progressSummary == nil ? .center : .leading)
            .foregroundStyle(.white)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(BookOpeningButtonStyle())
        .accessibilityLabel(L10n.string(hasProgress ? "forum.thread_route.continue_novel" : "forum.thread_route.read_novel"))
        .accessibilityValue(progressSummary ?? "")
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

struct ContentDetailActionIcon: View {
    @Environment(\.forumTheme) private var theme
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.medium))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(theme.accentText)
            .frame(width: 44)
            .frame(minHeight: 48, maxHeight: .infinity)
            .background(theme.mutedFill, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

struct ContentDetailFavoriteButton: View {
    let isFavorited: Bool
    let action: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: action) {
            ContentDetailActionIcon(systemImage: isFavorited ? "star.fill" : "star")
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() })
        .accessibilityLabel(L10n.string(isFavorited ? "forum.thread.favorited" : "forum.thread.favorite"))
        .help(L10n.string(isFavorited ? "forum.thread.favorited" : "forum.thread.favorite"))
    }
}

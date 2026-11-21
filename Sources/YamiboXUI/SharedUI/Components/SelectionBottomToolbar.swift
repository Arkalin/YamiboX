import SwiftUI

struct SelectionToolbarAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    var isEnabled: Bool = true
    /// Overrides `title` for VoiceOver, e.g. to speak a selected-count that
    /// isn't part of the visible caption. Falls back to `title` when nil.
    var accessibilityLabel: String? = nil
    let action: () -> Void
}

struct SelectionBottomToolbar: View {
    let actions: [SelectionToolbarAction]

    @ScaledMetric(relativeTo: .caption2) private var captionFontSize: CGFloat = 10

    var body: some View {
        SelectionToolbarEqualWidthLayout {
            ForEach(actions) { action in
                Button(role: action.role, action: action.action) {
                    VStack(spacing: 4) {
                        Image(systemName: action.systemImage)
                            .font(.body)
                        Text(action.title)
                            .font(.system(size: captionFontSize))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(minWidth: 64, maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(action.role == .destructive ? Color.red : Color.primary)
                    .opacity(action.isEnabled ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!action.isEnabled)
                .accessibilityLabel(action.accessibilityLabel ?? action.title)
                .anchorPreference(key: SelectionBottomToolbarActionAnchorKey.self, value: .bounds) {
                    [action.id: $0]
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct SelectionToolbarEqualWidthLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cell = widestIdealCell(of: subviews)
        if let proposed = proposal.width, proposed.isFinite {
            return CGSize(width: proposed, height: cell.height)
        }
        return CGSize(width: cell.width * CGFloat(subviews.count), height: cell.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let cellWidth = bounds.width / CGFloat(subviews.count)
        let cellProposal = ProposedViewSize(width: cellWidth, height: bounds.height)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + cellWidth * (CGFloat(index) + 0.5), y: bounds.midY),
                anchor: .center,
                proposal: cellProposal
            )
        }
    }

    private func widestIdealCell(of subviews: Subviews) -> CGSize {
        subviews.reduce(.zero) { cell, subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return CGSize(width: max(cell.width, ideal.width), height: max(cell.height, ideal.height))
        }
    }
}

/// Publishes each action button's frame, keyed by its `SelectionToolbarAction
/// .id`, up to whichever ancestor reads it via `.overlayPreferenceValue` —
/// e.g. an animation that flies a badge away from one specific button. Every
/// bar publishes this for free; most callers simply never read it.
struct SelectionBottomToolbarActionAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SelectionBottomToolbarCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }
}

extension View {
    func selectionBottomToolbarCapsule() -> some View {
        modifier(SelectionBottomToolbarCapsuleBackground())
    }
}

var usesSystemSelectionBottomToolbar: Bool {
    if #available(iOS 26.0, *) {
        return true
    }
    return false
}

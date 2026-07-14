import SwiftUI

/// One action shown in a `SelectionBottomToolbar`. Hide an action (don't
/// include it in the array) rather than merely disabling it when the
/// current selection can't use it at all — an available-but-empty selection
/// should make the whole bar disappear instead of showing dead buttons.
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

/// Shared multi-select bottom bar: icon-over-title buttons evenly split
/// across the available width, in the visual language originally designed
/// for the favorites screen. Every selection-mode screen in the app renders
/// through this one component instead of hand-rolling its own bar.
///
/// Mounting is always `ToolbarItem(placement: .bottomBar)`: on iOS 26+ the
/// system renders that placement as a floating Liquid Glass capsule on its
/// own, so this view stays bare there; earlier systems get a flat bar from
/// `.bottomBar` instead, so callers mount the same content via
/// `.safeAreaInset(edge: .bottom)` wrapped in `.selectionBottomToolbarCapsule()`
/// there to reproduce the floating-capsule look by hand. See
/// `usesSystemSelectionBottomToolbar` for the switch every call site uses to
/// pick between the two paths.
struct SelectionBottomToolbar: View {
    let actions: [SelectionToolbarAction]

    /// Matches the system tab bar's item title (`UITabBarItem` defaults to
    /// `UIFont.systemFont(ofSize: 10)`) — one point below `.caption2`, the
    /// smallest built-in `Font.TextStyle`, so no semantic style reaches it.
    /// `@ScaledMetric` keeps this fixed base scaling with Dynamic Type the
    /// way a plain `.system(size:)` wouldn't.
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
        // 6pt instead of a rounder 8-10: with the buttons' 44pt minimum
        // touch-target height this lands the capsule at ~61pt — the same
        // height as the system floating tab bar this bar replaces while
        // selection mode is active.
        .padding(.vertical, 6)
    }
}

/// Lays the action buttons out in equal-width cells sized to the widest
/// button, so the bar's *ideal* width already has room for every caption.
/// The iOS 26 system bottom bar sizes its floating Liquid Glass capsule to
/// that ideal — a plain `HStack` of `maxWidth: .infinity` buttons collapses
/// there to the sum of the buttons' tight sizes and then splits it evenly,
/// cramming the icons together and truncating the longest caption. Proposed
/// more than its ideal (the pre-iOS-26 full-width mounting), it spreads the
/// extra evenly across the cells, reproducing the classic full-width bar.
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

/// Reproduces the floating rounded-capsule Liquid Glass look by hand for
/// pre-iOS-26 systems, where a bare `.bottomBar` renders as a flat
/// edge-to-edge bar rather than a floating capsule.
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
    /// Applies the pre-iOS-26 floating-capsule background + outer margin to
    /// a `SelectionBottomToolbar` mounted via `.safeAreaInset`. Don't apply
    /// this to the iOS 26+ `ToolbarItem(placement: .bottomBar)` path — the
    /// system already supplies that look there.
    func selectionBottomToolbarCapsule() -> some View {
        modifier(SelectionBottomToolbarCapsuleBackground())
    }
}

/// Whether `ToolbarItem(placement: .bottomBar)` renders as a floating
/// Liquid Glass capsule on its own (iOS 26+). When false, callers fall back
/// to `.safeAreaInset(edge: .bottom)` + `.selectionBottomToolbarCapsule()`
/// to get the same look by hand.
var usesSystemSelectionBottomToolbar: Bool {
    if #available(iOS 26.0, *) {
        return true
    }
    return false
}

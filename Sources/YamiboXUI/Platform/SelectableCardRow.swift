import SwiftUI

/// Derived colors for content inside a selectable card row: entering
/// selection mode dims every row that isn't selected so the checked ones
/// stand out.
struct SelectionRowDimming {
    let isSelecting: Bool
    let isSelected: Bool

    var isDimmed: Bool {
        isSelecting && !isSelected
    }

    var titleColor: Color {
        isDimmed ? .secondary : .primary
    }

    var secondaryColor: Color {
        isDimmed ? Color.secondary.opacity(0.55) : .secondary
    }

    /// Accent-ish foregrounds (leading icons, failure text) collapse to the
    /// same dimmed gray as secondary text instead of keeping their hue.
    func emphasis(_ color: Color) -> Color {
        isDimmed ? Color.secondary.opacity(0.55) : color
    }
}

private struct SelectableCardRowModifier: ViewModifier {
    let isSelecting: Bool
    let isSelected: Bool
    let fill: Color
    let onTap: (() -> Void)?

    func body(content: Content) -> some View {
        let card = content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelecting && isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isSelected)

        return Group {
            if let onTap {
                card.onTapGesture(perform: onTap)
            } else {
                card
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// The shared chrome of a card-style row that can be multi-selected:
    /// rounded grouped background, accent stroke when selected, and the
    /// spring that animates the stroke in and out.
    func selectableCardRow(
        isSelecting: Bool,
        isSelected: Bool,
        fill: Color = YamiboColors.SystemSurface.secondaryGroupedBackground,
        onTap: (() -> Void)? = nil
    ) -> some View {
        modifier(SelectableCardRowModifier(
            isSelecting: isSelecting,
            isSelected: isSelected,
            fill: fill,
            onTap: onTap
        ))
    }

    /// The same card chrome for rows that never take part in selection.
    func cardRowChrome(
        fill: Color = YamiboColors.SystemSurface.secondaryGroupedBackground
    ) -> some View {
        selectableCardRow(isSelecting: false, isSelected: false, fill: fill)
    }
}

import SwiftUI

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

    func emphasis(_ color: Color) -> Color {
        isDimmed ? Color.secondary.opacity(0.55) : color
    }
}

private struct SelectableCardRowModifier: ViewModifier {
    let isSelecting: Bool
    let isSelected: Bool
    let fill: Color
    let onTap: (() -> Void)?
    @Environment(\.appTheme) private var appTheme

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
                    .strokeBorder(isSelecting && isSelected ? appTheme.controlAccent : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isSelected)

        return Group {
            if let onTap {
                // A real Button (not a bare tap gesture) so the row responds
                // on touch-down like every other pressable card.
                Button(action: onTap) { card }
                    .buttonStyle(PressableCardStyle())
            } else {
                card
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
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

    func cardRowChrome(
        fill: Color = YamiboColors.SystemSurface.secondaryGroupedBackground
    ) -> some View {
        selectableCardRow(isSelecting: false, isSelected: false, fill: fill)
    }
}

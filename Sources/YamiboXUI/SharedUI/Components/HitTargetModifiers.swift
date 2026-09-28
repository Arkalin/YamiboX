import SwiftUI

/// HIG requires interactive elements to be hittable in an area of at least
/// 44×44pt. These helpers bring undersized controls up to that floor.
extension View {
    /// Grows the view's layout frame to at least 44×44pt and makes the whole
    /// frame tappable. Use where the extra layout size is acceptable
    /// (standalone icon buttons, toolbar-like controls).
    func minimumHitTarget(
        width: CGFloat = 44,
        height: CGFloat = 44,
        alignment: Alignment = .center
    ) -> some View {
        frame(minWidth: width, minHeight: height, alignment: alignment)
            .contentShape(Rectangle())
    }

    /// Extends only the tappable area to at least 44×44pt, leaving layout
    /// untouched. Use inside dense rows or chip strips where growing the
    /// visual frame would disturb the design. The expanded area is centered,
    /// so it must not be clipped away by a tight ancestor for the overflow
    /// portion to receive touches.
    func expandedHitTarget(width: CGFloat = 44, height: CGFloat = 44) -> some View {
        background {
            Color.clear
                .frame(minWidth: width, minHeight: height)
                .contentShape(Rectangle())
        }
    }
}

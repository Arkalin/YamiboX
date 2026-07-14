#if canImport(UIKit)
import SwiftUI
import UIKit

extension Color {
    /// Linearly interpolates between `self` and `other` in RGBA space.
    /// `amount` 0 returns `self`, 1 returns `other`; values are clamped.
    func mix(with other: Color, amount: Double) -> Color {
        let clamped = min(max(amount, 0), 1)
        let lhs = UIColor(self)
        let rhs = UIColor(other)

        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        return Color(
            red: lr + (rr - lr) * clamped,
            green: lg + (rg - lg) * clamped,
            blue: lb + (rb - lb) * clamped,
            opacity: la + (ra - la) * clamped
        )
    }
}
#endif

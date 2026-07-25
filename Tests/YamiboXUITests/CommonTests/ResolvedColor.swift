import Foundation
import SwiftUI
import UIKit

/// A `Color` resolved to concrete sRGB components for one interface style,
/// with the WCAG contrast math restated here rather than reused from the app
/// so a readability test cannot pass by agreeing with a broken implementation.
struct ResolvedColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(_ color: Color, _ style: UIUserInterfaceStyle) {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // A translucent color has no contrast of its own until it is composited,
        // so it is flattened onto its surface by the caller, not here.
        self.red = Double(red)
        self.green = Double(green)
        self.blue = Double(blue)
    }

    func contrast(with other: ResolvedColor) -> Double {
        let brighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Resolved `UIColor` components round-trip through 8-bit storage, so
    /// equality is per-channel within half a step.
    static func == (lhs: ResolvedColor, rhs: ResolvedColor) -> Bool {
        abs(lhs.red - rhs.red) < 0.002
            && abs(lhs.green - rhs.green) < 0.002
            && abs(lhs.blue - rhs.blue) < 0.002
    }
}

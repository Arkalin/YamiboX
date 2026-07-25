import SwiftUI
import UIKit
import YamiboXCore

/// Re-lights the colors forum authors write into their posts so they stay
/// readable on the app's own surfaces.
///
/// Post markup carries fixed sRGB values, picked by their authors against the
/// site's light skin, and the reader paints them onto a dark card in dark
/// mode. Applied verbatim `color="black"` measures 1.24:1 there, and a
/// `[backcolor]` highlight leaves the theme's near-white body ink on the
/// author's light background at 1.14:1 — both far under the 4.5:1 floor for
/// body text. So foregrounds are lightened for the dark scheme only, and a run
/// carrying its own background gets an ink derived from that background rather
/// than the scheme-adaptive one.
enum ForumThreadAuthorColorAdapter {
    /// The colors one style run contributes; `nil` means "inherit the theme".
    struct RunColors {
        var foreground: Color?
        var background: Color?
    }

    static func colors(for style: ForumThreadTextStyle) -> RunColors {
        guard let background = RGBColor(forumThreadHex: style.backgroundHex) else {
            return RunColors(foreground: adaptedForeground(hex: style.foregroundHex), background: nil)
        }
        // An authored background is one fixed color in both schemes, so the
        // text on it has to be fixed too — the scheme-adaptive body ink
        // resolves to near-white and vanishes on a light highlight. An
        // authored foreground was already chosen against this background, so
        // it stays verbatim; otherwise whichever theme ink reads better on the
        // background wins.
        let foreground = RGBColor(forumThreadHex: style.foregroundHex) ?? ink(on: background)
        return RunColors(foreground: Color(foreground), background: Color(background))
    }

    /// Link color for a link sitting inside a run with an authored background.
    /// Without such a background the scheme-adaptive theme color is right.
    static func linkColor(onBackgroundHex hex: String?) -> Color {
        guard let background = RGBColor(forumThreadHex: hex) else {
            return ForumColors.brownPrimary
        }
        let light = RGBColor(hex: ForumColors.brownPrimaryLightHex)
        let dark = RGBColor(hex: ForumColors.brownPrimaryDarkHex)
        let readable = RGBColor.contrast(light, background) >= RGBColor.contrast(dark, background) ? light : dark
        return Color(readable)
    }

    /// WCAG AA for body text.
    private static let minimumContrast: Double = 4.5
    /// Below this saturation an authored color carries no hue worth keeping:
    /// someone writing `#333333` meant "the normal text color", not a grey.
    private static let achromaticSaturation: Double = 0.10
    private static let nearBlackLightness: Double = 0.25

    private static let darkSurface = RGBColor(hex: ForumColors.creamSurfaceDarkHex)
    private static let inkOnDarkSurface = RGBColor(hex: ForumColors.textDarkDarkHex)
    private static let inkOnLightSurface = RGBColor(hex: ForumColors.textDarkLightHex)

    private static func adaptedForeground(hex: String?) -> Color? {
        guard let authored = RGBColor(forumThreadHex: hex) else { return nil }
        return Color(light: authored, dark: lightenedForDarkSurface(authored))
    }

    /// The post card is the lightest surface a text block sits on, so a color
    /// that clears contrast there also clears quotes, table cells, and the
    /// page background, which are all deeper.
    private static func lightenedForDarkSurface(_ color: RGBColor) -> RGBColor {
        guard RGBColor.contrast(color, darkSurface) < minimumContrast else { return color }
        var hsl = color.hsl
        if hsl.saturation <= achromaticSaturation, hsl.lightness <= nearBlackLightness {
            return inkOnDarkSurface
        }
        // Hue and saturation are the author's expression, so only lightness
        // moves, and only far enough to clear the floor. Contrast against a
        // fixed dark surface rises monotonically with lightness, so bisecting
        // on it converges on the least invasive value.
        var tooDark = hsl.lightness
        var readable = 1.0
        for _ in 0 ..< 20 {
            let candidate = (tooDark + readable) / 2
            hsl.lightness = candidate
            if RGBColor.contrast(RGBColor(hsl: hsl), darkSurface) < minimumContrast {
                tooDark = candidate
            } else {
                readable = candidate
            }
        }
        hsl.lightness = readable
        return RGBColor(hsl: hsl)
    }

    private static func ink(on background: RGBColor) -> RGBColor {
        RGBColor.contrast(inkOnDarkSurface, background) >= RGBColor.contrast(inkOnLightSurface, background)
            ? inkOnDarkSurface
            : inkOnLightSurface
    }
}

private struct HSLColor {
    /// Degrees, `0 ..< 360`.
    var hue: Double
    var saturation: Double
    var lightness: Double
}

private struct RGBColor {
    var red: Double
    var green: Double
    var blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// Parses the `#RRGGBB` spelling `ForumThreadTextStyleParser` normalizes to.
    init?(forumThreadHex hex: String?) {
        guard let hex else { return nil }
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else {
            return nil
        }
        self.init(hex: UInt32(value))
    }

    init(hsl: HSLColor) {
        let chroma = (1 - abs(2 * hsl.lightness - 1)) * hsl.saturation
        let sextant = hsl.hue / 60
        let secondary = chroma * (1 - abs(sextant.truncatingRemainder(dividingBy: 2) - 1))
        let offset = hsl.lightness - chroma / 2
        let components: (Double, Double, Double) = switch sextant {
        case ..<1: (chroma, secondary, 0)
        case ..<2: (secondary, chroma, 0)
        case ..<3: (0, chroma, secondary)
        case ..<4: (0, secondary, chroma)
        case ..<5: (secondary, 0, chroma)
        default: (chroma, 0, secondary)
        }
        red = components.0 + offset
        green = components.1 + offset
        blue = components.2 + offset
    }

    var hsl: HSLColor {
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let delta = highest - lowest
        let lightness = (highest + lowest) / 2
        guard delta > 0 else {
            return HSLColor(hue: 0, saturation: 0, lightness: lightness)
        }
        let hue: Double
        if highest == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if highest == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        return HSLColor(
            hue: hue < 0 ? hue + 360 : hue,
            saturation: delta / (1 - abs(2 * lightness - 1)),
            lightness: lightness
        )
    }

    /// WCAG 2.1 relative luminance.
    var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    static func contrast(_ first: RGBColor, _ second: RGBColor) -> Double {
        let brighter = max(first.relativeLuminance, second.relativeLuminance)
        let darker = min(first.relativeLuminance, second.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }
}

private extension Color {
    init(_ rgb: RGBColor) {
        self.init(uiColor: UIColor(rgb))
    }

    init(light: RGBColor, dark: RGBColor) {
        self.init(uiColor: UIColor { traitCollection in
            UIColor(traitCollection.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(_ rgb: RGBColor) {
        self.init(
            red: min(max(rgb.red, 0), 1),
            green: min(max(rgb.green, 0), 1),
            blue: min(max(rgb.blue, 0), 1),
            alpha: 1
        )
    }
}

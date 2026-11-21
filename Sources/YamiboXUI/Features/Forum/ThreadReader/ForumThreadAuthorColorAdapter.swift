import SwiftUI
import UIKit
import YamiboXCore

enum ForumThreadAuthorColorAdapter {
    struct RunColors {
        var foreground: Color?
        var background: Color?
    }

    static func colors(for style: ForumThreadTextStyle, theme: ForumTheme = .classic) -> RunColors {
        guard let background = RGBColor(forumThreadHex: style.backgroundHex) else {
            return RunColors(
                foreground: adaptedForeground(hex: style.foregroundHex, theme: theme),
                background: nil
            )
        }
        if background.alpha < 1 {
            let light = background.composited(over: resolved(theme.pageBackground, style: .light))
            let dark = background.composited(over: resolved(theme.surface, style: .dark))
            let authored = RGBColor(forumThreadHex: style.foregroundHex)
            return RunColors(
                foreground: authored.map(Color.init) ?? Color(light: ink(on: light, theme: theme), dark: ink(on: dark, theme: theme)),
                background: Color(background)
            )
        }
        let foreground = RGBColor(forumThreadHex: style.foregroundHex) ?? ink(on: background, theme: theme)
        return RunColors(foreground: Color(foreground), background: Color(background))
    }

    static func linkColor(onBackgroundHex hex: String?, theme: ForumTheme = .classic) -> Color {
        guard let background = RGBColor(forumThreadHex: hex) else {
            return theme.actionText
        }
        let light = resolved(theme.actionText, style: .light)
        let dark = resolved(theme.actionText, style: .dark)
        if background.alpha < 1 {
            let lightSurface = background.composited(over: resolved(theme.pageBackground, style: .light))
            let darkSurface = background.composited(over: resolved(theme.surface, style: .dark))
            return Color(
                light: relit(light, on: lightSurface, fallbackInk: ink(on: lightSurface, theme: theme)),
                dark: relit(dark, on: darkSurface, fallbackInk: ink(on: darkSurface, theme: theme))
            )
        }
        let readable = RGBColor.contrast(light, background) >= RGBColor.contrast(dark, background) ? light : dark
        return Color(readable)
    }

    private static let minimumContrast: Double = 4.5
    private static let achromaticSaturation: Double = 0.10
    private static let nearBlackLightness: Double = 0.25
    private static let nearWhiteLightness: Double = 0.75

    private static func adaptedForeground(hex: String?, theme: ForumTheme) -> Color? {
        guard let authored = RGBColor(forumThreadHex: hex) else { return nil }
        if authored.alpha < 1 { return Color(authored) }
        let lightSurface = resolved(theme.pageBackground, style: .light)
        let darkSurface = resolved(theme.surface, style: .dark)
        let inkOnLightSurface = resolved(theme.primaryText, style: .light)
        let inkOnDarkSurface = resolved(theme.primaryText, style: .dark)
        return Color(
            light: relit(authored, on: lightSurface, fallbackInk: inkOnLightSurface),
            dark: relit(authored, on: darkSurface, fallbackInk: inkOnDarkSurface)
        )
    }

    private static func relit(
        _ color: RGBColor,
        on surface: RGBColor,
        fallbackInk: RGBColor
    ) -> RGBColor {
        guard RGBColor.contrast(color, surface) < minimumContrast else { return color }
        let towardsLight = RGBColor.contrast(.white, surface) >= RGBColor.contrast(.black, surface)
        var hsl = color.hsl
        if hsl.saturation <= achromaticSaturation {
            if towardsLight ? hsl.lightness <= nearBlackLightness : hsl.lightness >= nearWhiteLightness {
                return fallbackInk
            }
        }
        var unreadable = hsl.lightness
        var readable = towardsLight ? 1.0 : 0.0
        for _ in 0 ..< 20 {
            let candidate = (unreadable + readable) / 2
            hsl.lightness = candidate
            if RGBColor.contrast(RGBColor(hsl: hsl), surface) < minimumContrast {
                unreadable = candidate
            } else {
                readable = candidate
            }
        }
        hsl.lightness = readable
        return RGBColor(hsl: hsl)
    }

    private static func ink(on background: RGBColor, theme: ForumTheme) -> RGBColor {
        let inkOnDarkSurface = resolved(theme.primaryText, style: .dark)
        let inkOnLightSurface = resolved(theme.primaryText, style: .light)
        return RGBColor.contrast(inkOnDarkSurface, background) >= RGBColor.contrast(inkOnLightSurface, background)
            ? inkOnDarkSurface
            : inkOnLightSurface
    }

    private static func resolved(_ color: Color, style: UIUserInterfaceStyle) -> RGBColor {
        let traits = UITraitCollection(userInterfaceStyle: style)
        return RGBColor(UIColor(color).resolvedColor(with: traits))
    }
}

private struct HSLColor {
    var hue: Double
    var saturation: Double
    var lightness: Double
}

private struct RGBColor {
    static let white = RGBColor(hex: 0xFFFFFF)
    static let black = RGBColor(hex: 0x000000)

    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(_ color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.red = Double(red)
        self.green = Double(green)
        self.blue = Double(blue)
        self.alpha = Double(alpha)
    }

    init?(forumThreadHex hex: String?) {
        guard let hex else { return nil }
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard [6, 8].contains(normalized.count), let value = UInt64(normalized, radix: 16) else {
            return nil
        }
        self.init(hex: UInt32(normalized.count == 8 ? value >> 8 : value))
        if normalized.count == 8 { alpha = Double(value & 0xFF) / 255 }
    }

    func composited(over background: RGBColor) -> RGBColor {
        var result = RGBColor(hex: 0)
        result.red = red * alpha + background.red * (1 - alpha)
        result.green = green * alpha + background.green * (1 - alpha)
        result.blue = blue * alpha + background.blue * (1 - alpha)
        return result
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
            alpha: min(max(rgb.alpha, 0), 1)
        )
    }
}

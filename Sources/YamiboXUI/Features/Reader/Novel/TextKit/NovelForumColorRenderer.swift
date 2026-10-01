import UIKit
import YamiboXCore

/// Resolves authored colors against the reader's paper, rather than the forum's card.
enum NovelForumColorRenderer {
    static func color(hex: String?) -> UIColor? {
        guard let hex else { return nil }
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard [6, 8].contains(digits.count), let value = UInt64(digits, radix: 16) else { return nil }
        let rgb = digits.count == 8 ? value >> 8 : value
        let alpha = digits.count == 8 ? CGFloat(value & 0xFF) / 255 : 1
        return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255,
                       alpha: alpha)
    }

    static func quoteBackground(for settings: NovelReaderAppearanceSettings) -> UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark { return UIColor(white: 1, alpha: 0.10) }
            switch settings.backgroundStyle {
            case .system: return UIColor(white: 1, alpha: 0.58)
            case .paper: return UIColor(red: 1, green: 0.97, blue: 0.88, alpha: 0.68)
            case .mint: return UIColor(white: 1, alpha: 0.62)
            case .sakura: return UIColor(white: 1, alpha: 0.60)
            case .quiet: return UIColor(white: 1, alpha: 0.08)
            }
        }
    }

    static func foreground(
        authoredHex: String?, backgroundHex: String?,
        isQuote: Bool, settings: NovelReaderAppearanceSettings
    ) -> UIColor {
        UIColor { traits in
            let paper = readerThemeUIColor(for: settings.backgroundStyle, traitCollection: traits)
            let quotePaper = isQuote && settings.forumFormat.quote
                ? composite(quoteBackground(for: settings).resolvedColor(with: traits), over: paper)
                : paper
            let background = color(hex: backgroundHex).map { composite($0, over: quotePaper) } ?? quotePaper
            let ink = readerThemeTextUIColor(for: settings.backgroundStyle).resolvedColor(with: traits)
            let authored = color(hex: authoredHex)
            let foreground = authored.map { composite($0, over: background) } ?? ink
            if contrast(foreground, background) >= 4.5 { return authored ?? ink }
            let black = UIColor.black
            let white = UIColor.white
            let target = contrast(black, background) > contrast(white, background) ? black : white
            var low: CGFloat = 0
            var high: CGFloat = 1
            for _ in 0..<20 {
                let middle = (low + high) / 2
                if contrast(blend(foreground, target, fraction: middle), background) >= 4.5 {
                    high = middle
                } else {
                    low = middle
                }
            }
            let adapted = blend(foreground, target, fraction: high)
            return contrast(adapted, background) >= 4.5 ? adapted : ink
        }
    }

    private static func channels(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    private static func blend(_ first: UIColor, _ second: UIColor, fraction: CGFloat) -> UIColor {
        let a = channels(first)
        let b = channels(second)
        return UIColor(red: a.0 + (b.0 - a.0) * fraction,
                       green: a.1 + (b.1 - a.1) * fraction,
                       blue: a.2 + (b.2 - a.2) * fraction,
                       alpha: 1)
    }

    private static func composite(_ foreground: UIColor, over background: UIColor) -> UIColor {
        let a = channels(foreground)
        let b = channels(background)
        return UIColor(red: a.0 * a.3 + b.0 * (1 - a.3),
                       green: a.1 * a.3 + b.1 * (1 - a.3),
                       blue: a.2 * a.3 + b.2 * (1 - a.3),
                       alpha: 1)
    }

    private static func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ color: UIColor) -> Double {
        let values = channels(color)
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(values.0) + 0.7152 * linear(values.1) + 0.0722 * linear(values.2)
    }
}

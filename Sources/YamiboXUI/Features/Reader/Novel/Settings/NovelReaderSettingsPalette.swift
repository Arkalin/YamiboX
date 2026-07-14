import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct NovelReaderSheetPalette {
    let isNightMode: Bool
    let heroBackground: Color
    let bodyBackground: Color
    let cardBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let segmentedBackground: Color
    let divider: Color
    let headerButtonBackground: Color
    let confirmButtonBackground: Color

    init(settings: NovelReaderAppearanceSettings, colorScheme: ColorScheme) {
        let isNightMode = colorScheme == .dark
        let heroBackground = readerThemeColor(for: settings.backgroundStyle, colorScheme: colorScheme)
        let bodyBackground: Color
        let cardBackground: Color

        if isNightMode {
            bodyBackground = heroBackground.mix(with: Color(red: 0.08, green: 0.09, blue: 0.10), amount: 0.24)
            cardBackground = bodyBackground.mix(with: .white, amount: 0.08)
        } else {
            bodyBackground = heroBackground.mix(with: Color(red: 0.98, green: 0.98, blue: 0.99), amount: 0.72)
            cardBackground = bodyBackground.mix(with: .white, amount: 0.35)
        }

        self.isNightMode = isNightMode
        self.heroBackground = heroBackground
        self.bodyBackground = bodyBackground
        self.cardBackground = cardBackground
        primaryText = isNightMode
            ? Color.white.opacity(0.92)
            : Color(red: 0.09, green: 0.08, blue: 0.10)
        secondaryText = isNightMode
            ? Color.white.opacity(0.68)
            : Color.black.opacity(0.56)
        segmentedBackground = isNightMode
            ? bodyBackground.mix(with: .white, amount: 0.05)
            : bodyBackground.mix(with: Color.black, amount: 0.03)
        divider = isNightMode
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.08)
        headerButtonBackground = isNightMode
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.78)
        confirmButtonBackground = isNightMode
            ? heroBackground.mix(with: Color(red: 0.44, green: 0.39, blue: 0.30), amount: 0.58)
            : heroBackground.mix(with: Color(red: 0.31, green: 0.26, blue: 0.18), amount: 0.72)
    }
}


private struct NovelReaderThemeColorComponents {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

private func readerThemeColorComponents(
    for style: ReaderBackgroundStyle,
    colorScheme: ColorScheme
) -> NovelReaderThemeColorComponents {
    if colorScheme == .dark {
        switch style {
        case .system:
            return NovelReaderThemeColorComponents(red: 0.15, green: 0.16, blue: 0.18, alpha: 1)
        case .paper:
            return NovelReaderThemeColorComponents(red: 0.21, green: 0.19, blue: 0.16, alpha: 1)
        case .mint:
            return NovelReaderThemeColorComponents(red: 0.14, green: 0.18, blue: 0.16, alpha: 1)
        case .sakura:
            return NovelReaderThemeColorComponents(red: 0.19, green: 0.16, blue: 0.18, alpha: 1)
        }
    }

    switch style {
    case .system:
        return NovelReaderThemeColorComponents(red: 0.95, green: 0.94, blue: 0.91, alpha: 1)
    case .paper:
        return NovelReaderThemeColorComponents(red: 0.945, green: 0.882, blue: 0.769, alpha: 1)
    case .mint:
        return NovelReaderThemeColorComponents(red: 0.92, green: 0.97, blue: 0.93, alpha: 1)
    case .sakura:
        return NovelReaderThemeColorComponents(red: 0.97, green: 0.92, blue: 0.93, alpha: 1)
    }
}

func readerThemeColor(for style: ReaderBackgroundStyle, colorScheme: ColorScheme) -> Color {
    readerThemeColorComponents(for: style, colorScheme: colorScheme).color
}

func readerThemeUIColor(for style: ReaderBackgroundStyle, colorScheme: ColorScheme) -> UIColor {
    readerThemeColorComponents(for: style, colorScheme: colorScheme).uiColor
}

func readerThemeUIColor(for style: ReaderBackgroundStyle, traitCollection: UITraitCollection) -> UIColor {
    readerThemeUIColor(
        for: style,
        colorScheme: traitCollection.userInterfaceStyle == .dark ? .dark : .light
    )
}

#endif

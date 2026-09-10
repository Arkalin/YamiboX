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
    let heroText: Color
    let secondaryText: Color
    let segmentedBackground: Color
    let divider: Color
    let headerButtonBackground: Color
    let controlAccent: Color
    let confirmButtonBackground: Color
    let selectedControlText: Color

    init(
        settings: NovelReaderAppearanceSettings,
        colorScheme: ColorScheme,
        controlAccent: Color
    ) {
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
            ? ReaderSettingsPaletteTokens.darkPrimaryText
            : Color(red: 0.09, green: 0.08, blue: 0.10)
        heroText = settings.backgroundStyle == .quiet
            ? Color(uiColor: readerThemeTextUIColor(for: .quiet).resolvedColor(with:
                UITraitCollection(userInterfaceStyle: isNightMode ? .dark : .light)))
            : primaryText
        secondaryText = isNightMode
            ? Color.white.opacity(0.68)
            : Color.black.opacity(0.56)
        segmentedBackground = isNightMode
            ? bodyBackground.mix(with: .white, amount: 0.05)
            : bodyBackground.mix(with: Color.black, amount: 0.03)
        divider = ReaderSettingsPaletteTokens.divider(isDark: isNightMode)
        headerButtonBackground = isNightMode
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.78)
        self.controlAccent = controlAccent
        confirmButtonBackground = controlAccent
        selectedControlText = ReaderSettingsPaletteTokens.selectedControlText(isDark: isNightMode)
    }
}

extension NovelReaderSheetPalette: ReaderSettingsPalette {
    /// The Novel sheet has no dedicated card stroke; its cards have always
    /// been outlined with the divider hairline.
    var sectionStroke: Color { divider }

    /// Selected controls share the application accent while the reader
    /// preview and sheet backgrounds retain the reader's own palette.
    var selectedControlBackground: Color { confirmButtonBackground }
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
        case .quiet:
            return NovelReaderThemeColorComponents(red: 1 / 255, green: 1 / 255, blue: 1 / 255, alpha: 1)
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
    case .quiet:
        return NovelReaderThemeColorComponents(red: 74 / 255, green: 73 / 255, blue: 79 / 255, alpha: 1)
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

func readerThemeTextUIColor(for style: ReaderBackgroundStyle) -> UIColor {
    UIColor { traits in
        // Opaque screenshot-matched colors keep Quiet's text independent of its backdrop.
        if traits.userInterfaceStyle == .dark {
            return style == .quiet
                ? UIColor(red: 142 / 255, green: 142 / 255, blue: 144 / 255, alpha: 1)
                : UIColor(white: 1, alpha: 0.86)
        }
        switch style {
        case .system, .paper:
            return UIColor(red: 0.23, green: 0.19, blue: 0.15, alpha: 1)
        case .mint:
            return UIColor(red: 0.15, green: 0.21, blue: 0.18, alpha: 1)
        case .sakura:
            return UIColor(red: 0.23, green: 0.17, blue: 0.19, alpha: 1)
        case .quiet:
            return UIColor(red: 235 / 255, green: 234 / 255, blue: 240 / 255, alpha: 1)
        }
    }
}

#endif

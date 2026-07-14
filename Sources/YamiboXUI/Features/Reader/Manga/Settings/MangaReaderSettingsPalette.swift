import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaReaderSettingsPalette {
    let heroBackground: Color
    let bodyBackground: Color
    let cardBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let segmentedBackground: Color
    let selectedControlBackground: Color
    let selectedControlText: Color
    let divider: Color
    let cardStroke: Color
    let accent: Color
    let warmAccent: Color
    let confirmButtonBackground: Color
    let previewFrameBackground: Color
    let previewPageBackground: Color
    let warmPanel: Color
    let coolPanel: Color
    let neutralPanel: Color

    init(colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark
        let cool = Color(red: 0.10, green: 0.64, blue: 0.68)
        let warm = Color(red: 0.93, green: 0.36, blue: 0.43)
        let controlAccent = Color.accentColor
        let ink = Color(red: 0.08, green: 0.08, blue: 0.09)

        if isDark {
            let sheetBackground = Color(red: 0.10, green: 0.10, blue: 0.11)
            bodyBackground = sheetBackground
            heroBackground = sheetBackground
            cardBackground = Color.white.opacity(0.075)
            primaryText = Color.white.opacity(0.92)
            secondaryText = Color.white.opacity(0.66)
            segmentedBackground = Color.white.opacity(0.07)
            selectedControlBackground = controlAccent
            selectedControlText = Color.white
            divider = Color.white.opacity(0.08)
            cardStroke = Color.white.opacity(0.10)
            previewFrameBackground = Color.black.opacity(0.26)
            previewPageBackground = Color(red: 0.88, green: 0.88, blue: 0.84)
            neutralPanel = Color.black.opacity(0.16)
            confirmButtonBackground = sheetBackground.mix(with: Color(red: 0.44, green: 0.39, blue: 0.30), amount: 0.58)
        } else {
            let heroSurfaceBackground = Color.white
            heroBackground = heroSurfaceBackground
            bodyBackground = Color.white
            cardBackground = Color.white.opacity(0.78)
            primaryText = ink
            secondaryText = Color.black.opacity(0.55)
            segmentedBackground = Color.black.opacity(0.045)
            selectedControlBackground = controlAccent
            selectedControlText = Color.white
            divider = Color.black.opacity(0.08)
            cardStroke = Color.black.opacity(0.08)
            previewFrameBackground = Color.black.opacity(0.08)
            previewPageBackground = Color.white
            neutralPanel = Color.black.opacity(0.08)
            confirmButtonBackground = heroSurfaceBackground.mix(
                with: Color(red: 0.31, green: 0.26, blue: 0.18),
                amount: 0.72
            )
        }

        accent = controlAccent
        warmAccent = controlAccent
        warmPanel = warm.opacity(isDark ? 0.52 : 0.34)
        coolPanel = cool.opacity(isDark ? 0.52 : 0.30)
    }
}


#endif

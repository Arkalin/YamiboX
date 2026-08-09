import SwiftUI
import Testing
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

@Test func everyForumPresetMapsToADistinctTheme() {
    let themes = ForumThemePreset.allCases.map(ForumTheme.theme(for:))

    #expect(themes.map(\.id) == ForumThemePreset.allCases.map(\.rawValue))
    #expect(Set(themes.map(\.id)).count == ForumThemePreset.allCases.count)
}

@Test func forumPresetPalettesKeepTheirApprovedAnchorColors() {
    let anchors: [(ForumThemePreset, UInt32, UInt32, UInt32, UInt32)] = [
        (.standard, 0xF2F2F7, 0x111214, 0x2C2C2E, 0x2C2C2E),
        (.classic, 0xFFF3D6, 0x17110D, 0x4E2A1B, 0x24120C),
        (.teal, 0xEDF5F3, 0x0F1717, 0x155257, 0x103F42),
        (.rose, 0xF7F1F3, 0x181315, 0x713047, 0x512134)
    ]

    for (preset, lightPage, darkPage, lightNavigation, darkNavigation) in anchors {
        let theme = ForumTheme.theme(for: preset)
        #expect(ResolvedColor(theme.pageBackground, .light) == ResolvedColor(hex: lightPage))
        #expect(ResolvedColor(theme.pageBackground, .dark) == ResolvedColor(hex: darkPage))
        #expect(ResolvedColor(theme.navigationBarBackgroundLight, .light) == ResolvedColor(hex: lightNavigation))
        #expect(ResolvedColor(theme.navigationBarBackgroundDark, .dark) == ResolvedColor(hex: darkNavigation))
    }
}

@Test func standardForumThemeUsesOnlyNeutralAccentColors() {
    let theme = ForumTheme.standard
    let colors = [theme.accent, theme.accentText, theme.mutedAccent, theme.webText]

    for style in [UIUserInterfaceStyle.light, .dark] {
        for color in colors + [theme.navigationBarBackground(for: style == .light ? .light : .dark)] {
            let resolved = ResolvedColor(color, style)
            #expect(abs(resolved.red - resolved.green) < 0.03)
            #expect(abs(resolved.green - resolved.blue) < 0.03)
        }
    }
}

@Test func classicForumThemeKeepsTheCurrentForumPalette() {
    let theme = ForumTheme.classic

    #expect(theme.id == "classic")
    #expect(ResolvedColor(theme.accent, .light) == ResolvedColor(hex: 0x4E2A1B))
    #expect(ResolvedColor(theme.pageBackground, .light) == ResolvedColor(hex: 0xFFF3D6))
    #expect(ResolvedColor(theme.surface, .dark) == ResolvedColor(hex: 0x241B15))
}

@Test func forumNavigationBarBackgroundStaysFixedPerScheme() {
    let theme = ForumTheme.classic

    #expect(ResolvedColor(theme.navigationBarBackgroundLight, .light) == ResolvedColor(hex: 0x4E2A1B))
    #expect(ResolvedColor(theme.navigationBarBackgroundDark, .dark) == ResolvedColor(hex: 0x24120C))
    #expect(ResolvedColor(theme.navigationBarBackground(for: .light), .light) == ResolvedColor(hex: 0x4E2A1B))
    #expect(ResolvedColor(theme.navigationBarBackground(for: .dark), .dark) == ResolvedColor(hex: 0x24120C))
}

@Test func readerAccentIsOwnedByTheReaderTheme() {
    #expect(ReaderTheme.accent == AppColors.accent)
}

@Test func mangaSettingsPaletteUsesTheReaderAccentForSelectedControls() {
    let palette = MangaReaderSettingsPalette(colorScheme: .light)

    #expect(palette.accent == ReaderTheme.accent)
    #expect(palette.warmAccent == ReaderTheme.accent)
    #expect(palette.selectedControlBackground == ReaderTheme.accent)
}

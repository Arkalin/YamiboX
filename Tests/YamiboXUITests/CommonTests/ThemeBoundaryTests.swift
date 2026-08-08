import SwiftUI
import Testing
import UIKit
@testable import YamiboXUI

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

import SwiftUI
import Testing
import UIKit
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@Test func everyAppPresetMapsToADistinctTheme() {
    let themes = AppThemePreset.allCases.map(AppTheme.theme(for:))

    #expect(themes.map(\.id) == AppThemePreset.allCases.map(\.rawValue))
    #expect(Set(themes.map(\.id)).count == AppThemePreset.allCases.count)
}

@Test func appThemeUsesItsForumAccentTextForGlobalControls() {
    for preset in AppThemePreset.allCases {
        let appTheme = AppTheme.theme(for: preset)

        #expect(appTheme.id == preset.rawValue)
        #expect(appTheme.controlAccent == appTheme.forumTheme.accentText)
    }
}

@Test func forumPresetPalettesKeepTheirApprovedAnchorColors() {
    let anchors: [(AppThemePreset, UInt32, UInt32, UInt32, UInt32)] = [
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

final class ThemeBoundaryXCTests: XCTestCase {
    func testPinnedForumSurfacesUseTheSelectedThemePalette() {
        let anchors: [(AppThemePreset, UInt32, UInt32, UInt32, UInt32)] = [
            (.standard, 0xECECED, 0xDCDCDE, 0x2E2F32, 0x3D3D41),
            (.classic, 0xEDE0CA, 0xDFCDB8, 0x392B22, 0x4B382D),
            (.teal, 0xE2EDEC, 0xCEDEDC, 0x243533, 0x2F4441),
            (.rose, 0xF0E6EA, 0xE4D5DB, 0x392B30, 0x4A383F)
        ]

        for (preset, lightPinned, lightAnnouncement, darkPinned, darkAnnouncement) in anchors {
            let theme = ForumTheme.theme(for: preset)

            XCTAssertEqual(ResolvedColor(theme.pinnedSurface, .light), ResolvedColor(hex: lightPinned))
            XCTAssertEqual(ResolvedColor(theme.announcementSurface, .light), ResolvedColor(hex: lightAnnouncement))
            XCTAssertEqual(ResolvedColor(theme.pinnedSurface, .dark), ResolvedColor(hex: darkPinned))
            XCTAssertEqual(ResolvedColor(theme.announcementSurface, .dark), ResolvedColor(hex: darkAnnouncement))

            for style in [UIUserInterfaceStyle.light, .dark] {
                XCTAssertEqual(
                    ResolvedColor(theme.pinnedBadgeFill, style),
                    ResolvedColor(theme.selectedFill, style)
                )
                XCTAssertNotEqual(
                    ResolvedColor(theme.pinnedBadgeFill, style),
                    ResolvedColor(theme.warningFill, style)
                )

                let text = ResolvedColor(theme.primaryText, style)
                for surface in [theme.pinnedSurface, theme.announcementSurface] {
                    XCTAssertGreaterThanOrEqual(text.contrast(with: ResolvedColor(surface, style)), 4.5)
                }
            }
        }
    }
}

extension ThemeBoundaryXCTests {
    func testReaderSettingsPalettesUseTheAppThemeAccentForControls() {
        for preset in AppThemePreset.allCases {
            let appTheme = AppTheme.theme(for: preset)
            let accent = ResolvedColor(appTheme.controlAccent, .light)
            let manga = MangaReaderSettingsPalette(
                colorScheme: .light,
                controlAccent: appTheme.controlAccent
            )
            let novel = NovelReaderSheetPalette(
                settings: NovelReaderAppearanceSettings(),
                colorScheme: .light,
                controlAccent: appTheme.controlAccent
            )

            XCTAssertEqual(ResolvedColor(manga.accent, .light), accent)
            XCTAssertEqual(ResolvedColor(manga.warmAccent, .light), accent)
            XCTAssertEqual(ResolvedColor(manga.selectedControlBackground, .light), accent)
            XCTAssertEqual(ResolvedColor(manga.confirmButtonBackground, .light), accent)
            XCTAssertEqual(ResolvedColor(manga.selectedControlText, .light), ResolvedColor(.white, .light))

            XCTAssertEqual(ResolvedColor(novel.controlAccent, .light), accent)
            XCTAssertEqual(ResolvedColor(novel.selectedControlBackground, .light), accent)
            XCTAssertEqual(ResolvedColor(novel.confirmButtonBackground, .light), accent)
            XCTAssertEqual(ResolvedColor(novel.selectedControlText, .light), ResolvedColor(.white, .light))
        }
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

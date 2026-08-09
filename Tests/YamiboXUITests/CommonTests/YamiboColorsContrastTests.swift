import Foundation
import SwiftUI
import Testing
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

/// WCAG AA for body text.
private let readableContrast = 4.5

@Test func forumTextRolesAreReadableOnForumSurfaces() {
    for preset in ForumThemePreset.allCases {
        let theme = ForumTheme.theme(for: preset)
        let roles: [(name: String, color: Color)] = [
            ("primaryText", theme.primaryText),
            ("secondaryText", theme.secondaryText),
            ("tertiaryText", theme.tertiaryText),
            ("accentText", theme.accentText),
            ("mutedAccent", theme.mutedAccent),
            ("webText", theme.webText),
            ("warning", theme.warning),
            ("danger", theme.danger)
        ]

        for style in [UIUserInterfaceStyle.light, .dark] {
            let surfaces = [theme.pageBackground, theme.surface].map { ResolvedColor($0, style) }
            for (name, color) in roles {
                for surface in surfaces {
                    let ratio = ResolvedColor(color, style).contrast(with: surface)
                    #expect(
                        ratio >= readableContrast,
                        "\(preset.rawValue).\(name) measures \(ratio):1 in \(style) mode"
                    )
                }
            }
        }
    }
}

@Test func forumTextRolesKeepTheirVisualHierarchy() {
    // Each weight must read as less prominent than the one above it, or the
    // contrast floor has flattened the palette into a single tone.
    for preset in ForumThemePreset.allCases {
        let theme = ForumTheme.theme(for: preset)
        for style in [UIUserInterfaceStyle.light, .dark] {
            for surfaceColor in [theme.pageBackground, theme.surface] {
                let surface = ResolvedColor(surfaceColor, style)
                let body = ResolvedColor(theme.primaryText, style).contrast(with: surface)
                let secondary = ResolvedColor(theme.secondaryText, style).contrast(with: surface)
                let tertiary = ResolvedColor(theme.tertiaryText, style).contrast(with: surface)

                #expect(body > secondary, "\(preset.rawValue) primaryText hierarchy failed in \(style) mode")
                #expect(secondary > tertiary, "\(preset.rawValue) secondaryText hierarchy failed in \(style) mode")
            }
        }
    }
}

@Test func forumControlAndBadgeTextMeetsContrastRequirements() {
    let white = ResolvedColor(hex: 0xFFFFFF)

    for preset in ForumThemePreset.allCases {
        let theme = ForumTheme.theme(for: preset)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let whiteTextSurfaces: [(String, Color)] = [
                ("button", theme.accent),
                ("navigation", theme.navigationBarBackground(for: style == .light ? .light : .dark)),
                ("dangerFill", theme.dangerFill)
            ]
            for (name, surface) in whiteTextSurfaces {
                let ratio = white.contrast(with: ResolvedColor(surface, style))
                #expect(
                    ratio >= readableContrast,
                    "\(preset.rawValue) white text on \(name) measures \(ratio):1 in \(style) mode"
                )
            }

            let warningRatio = ResolvedColor(theme.primaryText, style)
                .contrast(with: ResolvedColor(theme.warningFill, style))
            #expect(
                warningRatio >= readableContrast,
                "\(preset.rawValue) warning badge measures \(warningRatio):1 in \(style) mode"
            )
        }
    }
}

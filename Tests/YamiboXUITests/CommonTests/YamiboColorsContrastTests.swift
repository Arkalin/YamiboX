import Foundation
import SwiftUI
import Testing
import UIKit
@testable import YamiboXUI

/// The surfaces forum text lands on, worst case first: in dark mode the palest
/// one (the post card), in light mode the deepest one (the page and every
/// inset panel drawn on it).
private let forumSurfaces: [(style: UIUserInterfaceStyle, surface: ResolvedColor)] = [
    (.dark, ResolvedColor(hex: 0x241B15)),
    (.light, ResolvedColor(hex: 0xFFF3D6))
]
/// WCAG AA for body text.
private let readableContrast = 4.5

@Test func forumTextRolesAreReadableOnForumSurfaces() {
    // `orangeAccent` is deliberately absent: it measures 1.94:1 on the cream
    // page in light mode, and it is carrying text today (post manage actions,
    // rating scores). Deepening it would also restyle every star and badge
    // drawn in it, so splitting the icon and text roles apart is its own
    // change rather than something to fold in here.
    let roles: [(name: String, color: Color)] = [
        ("primaryText", ForumTheme.classic.primaryText),
        ("secondaryText", ForumTheme.classic.secondaryText),
        ("tertiaryText", ForumTheme.classic.tertiaryText),
        ("mutedAccent", ForumTheme.classic.mutedAccent),
        ("accentText", ForumTheme.classic.accentText),
        ("danger", ForumTheme.classic.danger)
    ]

    for (name, color) in roles {
        for (style, surface) in forumSurfaces {
            let ratio = ResolvedColor(color, style).contrast(with: surface)
            #expect(ratio >= readableContrast, "\(name) measures \(ratio):1 in \(style) mode")
        }
    }
}

@Test func forumTextRolesKeepTheirVisualHierarchy() {
    // Each weight must read as less prominent than the one above it, or the
    // contrast floor has flattened the palette into a single tone.
    for (style, surface) in forumSurfaces {
        let body = ResolvedColor(ForumTheme.classic.primaryText, style).contrast(with: surface)
        let secondary = ResolvedColor(ForumTheme.classic.secondaryText, style).contrast(with: surface)
        let tertiary = ResolvedColor(ForumTheme.classic.tertiaryText, style).contrast(with: surface)

        #expect(body > secondary, "primaryText is not stronger than secondaryText in \(style) mode")
        #expect(secondary > tertiary, "secondaryText is not stronger than tertiaryText in \(style) mode")
    }
}

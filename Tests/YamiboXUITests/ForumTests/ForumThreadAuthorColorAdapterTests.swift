import Foundation
import SwiftUI
import Testing
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

/// Surfaces and inks the adapter is expected to reason against, spelled out
/// independently of the production constants so a palette edit that breaks
/// readability fails a test instead of silently passing.
private let postCardDarkSurface = ResolvedColor(hex: 0x241B15)
private let pageLightSurface = ResolvedColor(hex: 0xFFF3D6)
private let bodyInkOnDarkSurface = ResolvedColor(hex: 0xF4E7D1)
private let bodyInkOnLightSurface = ResolvedColor(hex: 0x2E1A0E)
/// WCAG AA for body text.
private let readableContrast = 4.5

private func authoredColor(_ hex: String) -> ResolvedColor {
    ResolvedColor(hex: UInt32(hex.dropFirst(), radix: 16)!)
}

// MARK: - P0-1: authored foregrounds

@Test func darkAuthorForegroundIsLightenedForTheDarkSurfaceOnly() throws {
    // Colors an author would pick against the site's light skin; each one
    // measures under 2:1 on the app's dark card when applied verbatim.
    for hex in ["#00008B", "#8B0000", "#800080", "#0000FF"] {
        let color = try #require(ForumThreadAuthorColorAdapter.colors(
            for: ForumThreadTextStyle(foregroundHex: hex)
        ).foreground)

        let darkContrast = ResolvedColor(color, .dark).contrast(with: postCardDarkSurface)
        #expect(darkContrast >= readableContrast, "\(hex) stays unreadable in dark mode")

        // Light mode is where these colors already work — it must not move.
        let lightValue = ResolvedColor(color, .light)
        #expect(lightValue == authoredColor(hex), "\(hex) was altered in light mode")
    }
}

@Test func lightAuthorForegroundIsDarkenedForTheLightSurfaceOnly() throws {
    // The mirror case: pale colors are the ones that vanish on the cream page.
    for hex in ["#A9A9A9", "#F0E68C", "#ADD8E6"] {
        let color = try #require(ForumThreadAuthorColorAdapter.colors(
            for: ForumThreadTextStyle(foregroundHex: hex)
        ).foreground)

        let lightContrast = ResolvedColor(color, .light).contrast(with: pageLightSurface)
        #expect(lightContrast >= readableContrast, "\(hex) stays unreadable in light mode")

        let darkValue = ResolvedColor(color, .dark)
        #expect(darkValue == authoredColor(hex), "\(hex) was altered in dark mode")
    }
}

@Test func authorForegroundKeepsItsHueWhenLightened() throws {
    let color = try #require(ForumThreadAuthorColorAdapter.colors(
        for: ForumThreadTextStyle(foregroundHex: "#00008B")
    ).foreground)

    // Navy stays blue rather than washing out to grey or shifting channel.
    let lightened = ResolvedColor(color, .dark)
    #expect(lightened.blue > lightened.red)
    let redEqualsGreen = abs(lightened.red - lightened.green) < 0.01
    #expect(redEqualsGreen)
}

@Test func achromaticAuthorForegroundFallsBackToTheThemeBodyInk() throws {
    // `black` and `#333333` mean "the normal text color", and `white` means it
    // just as much on the far side, so they read as untinted body text rather
    // than washing out to a flat grey.
    for hex in ["#000000", "#333333"] {
        let color = try #require(ForumThreadAuthorColorAdapter.colors(
            for: ForumThreadTextStyle(foregroundHex: hex)
        ).foreground)

        let darkValue = ResolvedColor(color, .dark)
        #expect(darkValue == bodyInkOnDarkSurface, "\(hex) did not fall back to the body ink")
    }
    for hex in ["#FFFFFF", "#D3D3D3"] {
        let color = try #require(ForumThreadAuthorColorAdapter.colors(
            for: ForumThreadTextStyle(foregroundHex: hex)
        ).foreground)

        let lightValue = ResolvedColor(color, .light)
        #expect(lightValue == bodyInkOnLightSurface, "\(hex) did not fall back to the body ink")
    }
}

@Test func authorForegroundIsRelitOnlyWhereItIsUnreadable() throws {
    // Some authored colors work in one scheme and not the other, and mid-tones
    // like `#FF0000` (3.63:1 on the cream page, 4.23:1 on the dark card) work
    // in neither. Either way both schemes end up readable, and a scheme where
    // the author's choice already worked keeps it untouched.
    let surfaces: [(style: UIUserInterfaceStyle, surface: ResolvedColor)] = [
        (.light, pageLightSurface),
        (.dark, postCardDarkSurface)
    ]
    for hex in ["#000000", "#FFFFFF", "#FF0000", "#808080", "#00008B", "#FFFF00"] {
        let color = try #require(ForumThreadAuthorColorAdapter.colors(
            for: ForumThreadTextStyle(foregroundHex: hex)
        ).foreground)
        let authored = authoredColor(hex)

        for (style, surface) in surfaces {
            let relit = ResolvedColor(color, style)
            #expect(relit.contrast(with: surface) >= readableContrast, "\(hex) is unreadable in \(style) mode")
            if authored.contrast(with: surface) >= readableContrast {
                #expect(relit == authored, "\(hex) was relit in \(style) mode although it already worked there")
            }
        }
    }
}

@Test func invalidAuthorHexLeavesTheThemeColorInPlace() throws {
    let colors = ForumThreadAuthorColorAdapter.colors(for: ForumThreadTextStyle(foregroundHex: "not-a-color"))

    #expect(colors.foreground == nil)
    #expect(colors.background == nil)
}

// MARK: - P0-2: authored backgrounds

@Test func highlightRunGetsAFixedInkReadableOnItsOwnBackground() throws {
    // `[backcolor]` produces a background with no foreground. The theme's ink
    // is scheme-adaptive and resolves to near-white, which disappears on these.
    for hex in ["#FFFFFF", "#FFFF00", "#D3D3D3", "#00FFFF", "#90EE90"] {
        let colors = ForumThreadAuthorColorAdapter.colors(for: ForumThreadTextStyle(backgroundHex: hex))
        let foreground = try #require(colors.foreground)
        let background = try #require(colors.background)

        let authored = ResolvedColor(hex: UInt32(hex.dropFirst(), radix: 16)!)
        let backgroundValue = ResolvedColor(background, .dark)
        #expect(backgroundValue == authored, "\(hex) background was altered")

        // Fixed, not adaptive: the background is the same in both schemes, so
        // the ink on it has to be too.
        let darkInk = ResolvedColor(foreground, .dark)
        let lightInk = ResolvedColor(foreground, .light)
        #expect(darkInk == lightInk, "\(hex) ink still changes with the color scheme")
        #expect(darkInk == bodyInkOnLightSurface, "\(hex) did not pick the dark ink")
        #expect(darkInk.contrast(with: authored) >= readableContrast, "\(hex) ink is unreadable")
    }
}

@Test func darkHighlightGetsThePaleInk() throws {
    let colors = ForumThreadAuthorColorAdapter.colors(for: ForumThreadTextStyle(backgroundHex: "#000080"))
    let foreground = try #require(colors.foreground)

    let ink = ResolvedColor(foreground, .light)
    #expect(ink == bodyInkOnDarkSurface)
    #expect(ink.contrast(with: ResolvedColor(hex: 0x000080)) >= readableContrast)
}

@Test func authoredPairIsKeptVerbatimInBothSchemes() throws {
    // Both halves came from the same author against each other, so neither is
    // second-guessed — and neither may drift with the color scheme.
    let colors = ForumThreadAuthorColorAdapter.colors(
        for: ForumThreadTextStyle(foregroundHex: "#000000", backgroundHex: "#FFFFFF")
    )
    let foreground = try #require(colors.foreground)
    let background = try #require(colors.background)

    let darkForeground = ResolvedColor(foreground, .dark)
    let lightForeground = ResolvedColor(foreground, .light)
    #expect(darkForeground == ResolvedColor(hex: 0x000000))
    #expect(lightForeground == ResolvedColor(hex: 0x000000))
    let darkBackground = ResolvedColor(background, .dark)
    #expect(darkBackground == ResolvedColor(hex: 0xFFFFFF))
}

// MARK: - Links

@Test func linkOnAuthoredBackgroundBecomesFixedAndReadable() throws {
    let color = ForumThreadAuthorColorAdapter.linkColor(onBackgroundHex: "#FFFFFF")

    let darkValue = ResolvedColor(color, .dark)
    let lightValue = ResolvedColor(color, .light)
    #expect(darkValue == lightValue)
    #expect(darkValue.contrast(with: ResolvedColor(hex: 0xFFFFFF)) >= readableContrast)
}

@Test func linkWithoutAuthoredBackgroundKeepsTheAdaptiveThemeColor() throws {
    let color = ForumThreadAuthorColorAdapter.linkColor(onBackgroundHex: nil)

    #expect(color == ForumTheme.classic.mutedAccent)
}

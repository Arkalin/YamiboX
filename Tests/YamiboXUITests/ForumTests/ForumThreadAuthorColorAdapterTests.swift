import Foundation
import SwiftUI
import Testing
import UIKit
@testable import YamiboXCore
@testable import YamiboXUI

/// Surfaces and inks the adapter is expected to reason against, spelled out
/// independently of the production constants so a palette edit that breaks
/// readability fails a test instead of silently passing.
private let postCardDarkSurface = TestRGB(hex: 0x241B15)
private let bodyInkOnDarkSurface = TestRGB(hex: 0xF4E7D1)
private let bodyInkOnLightSurface = TestRGB(hex: 0x2E1A0E)
/// WCAG AA for body text.
private let readableContrast = 4.5

// MARK: - P0-1: authored foregrounds

@Test func authorForegroundIsLightenedOnlyForTheDarkSurface() throws {
    // Colors an author would pick against the site's light skin; each one
    // measures under 2:1 on the app's dark card when applied verbatim.
    for hex in ["#00008B", "#8B0000", "#800080", "#0000FF"] {
        let color = try #require(ForumThreadAuthorColorAdapter.colors(
            for: ForumThreadTextStyle(foregroundHex: hex)
        ).foreground)

        let darkContrast = TestRGB(color, .dark).contrast(with: postCardDarkSurface)
        #expect(darkContrast >= readableContrast, "\(hex) stays unreadable in dark mode")

        // Light mode is where these colors already work — it must not move.
        let lightValue = TestRGB(color, .light)
        let authored = TestRGB(hex: UInt32(hex.dropFirst(), radix: 16)!)
        #expect(lightValue == authored, "\(hex) was altered in light mode")
    }
}

@Test func authorForegroundKeepsItsHueWhenLightened() throws {
    let color = try #require(ForumThreadAuthorColorAdapter.colors(
        for: ForumThreadTextStyle(foregroundHex: "#00008B")
    ).foreground)

    // Navy stays blue rather than washing out to grey or shifting channel.
    let lightened = TestRGB(color, .dark)
    #expect(lightened.blue > lightened.red)
    let redEqualsGreen = abs(lightened.red - lightened.green) < 0.01
    #expect(redEqualsGreen)
}

@Test func nearBlackAuthorForegroundBecomesTheThemeBodyInk() throws {
    // `color="black"` and `#333333` mean "the normal text color", so they
    // should read as untinted body text rather than as a cold grey.
    for hex in ["#000000", "#333333"] {
        let color = try #require(ForumThreadAuthorColorAdapter.colors(
            for: ForumThreadTextStyle(foregroundHex: hex)
        ).foreground)

        let darkValue = TestRGB(color, .dark)
        #expect(darkValue == bodyInkOnDarkSurface, "\(hex) did not fall back to the body ink")
    }
}

@Test func alreadyReadableAuthorForegroundIsUntouched() throws {
    for hex in ["#FFFFFF", "#FFFF00", "#A9A9A9"] {
        let color = try #require(ForumThreadAuthorColorAdapter.colors(
            for: ForumThreadTextStyle(foregroundHex: hex)
        ).foreground)

        let authored = TestRGB(hex: UInt32(hex.dropFirst(), radix: 16)!)
        let darkValue = TestRGB(color, .dark)
        let lightValue = TestRGB(color, .light)
        #expect(darkValue == authored, "\(hex) was altered in dark mode")
        #expect(lightValue == authored, "\(hex) was altered in light mode")
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

        let authored = TestRGB(hex: UInt32(hex.dropFirst(), radix: 16)!)
        let backgroundValue = TestRGB(background, .dark)
        #expect(backgroundValue == authored, "\(hex) background was altered")

        // Fixed, not adaptive: the background is the same in both schemes, so
        // the ink on it has to be too.
        let darkInk = TestRGB(foreground, .dark)
        let lightInk = TestRGB(foreground, .light)
        #expect(darkInk == lightInk, "\(hex) ink still changes with the color scheme")
        #expect(darkInk == bodyInkOnLightSurface, "\(hex) did not pick the dark ink")
        #expect(darkInk.contrast(with: authored) >= readableContrast, "\(hex) ink is unreadable")
    }
}

@Test func darkHighlightGetsThePaleInk() throws {
    let colors = ForumThreadAuthorColorAdapter.colors(for: ForumThreadTextStyle(backgroundHex: "#000080"))
    let foreground = try #require(colors.foreground)

    let ink = TestRGB(foreground, .light)
    #expect(ink == bodyInkOnDarkSurface)
    #expect(ink.contrast(with: TestRGB(hex: 0x000080)) >= readableContrast)
}

@Test func authoredPairIsKeptVerbatimInBothSchemes() throws {
    // Both halves came from the same author against each other, so neither is
    // second-guessed — and neither may drift with the color scheme.
    let colors = ForumThreadAuthorColorAdapter.colors(
        for: ForumThreadTextStyle(foregroundHex: "#000000", backgroundHex: "#FFFFFF")
    )
    let foreground = try #require(colors.foreground)
    let background = try #require(colors.background)

    let darkForeground = TestRGB(foreground, .dark)
    let lightForeground = TestRGB(foreground, .light)
    #expect(darkForeground == TestRGB(hex: 0x000000))
    #expect(lightForeground == TestRGB(hex: 0x000000))
    let darkBackground = TestRGB(background, .dark)
    #expect(darkBackground == TestRGB(hex: 0xFFFFFF))
}

// MARK: - Links

@Test func linkOnAuthoredBackgroundBecomesFixedAndReadable() throws {
    let color = ForumThreadAuthorColorAdapter.linkColor(onBackgroundHex: "#FFFFFF")

    let darkValue = TestRGB(color, .dark)
    let lightValue = TestRGB(color, .light)
    #expect(darkValue == lightValue)
    #expect(darkValue.contrast(with: TestRGB(hex: 0xFFFFFF)) >= readableContrast)
}

@Test func linkWithoutAuthoredBackgroundKeepsTheAdaptiveThemeColor() throws {
    let color = ForumThreadAuthorColorAdapter.linkColor(onBackgroundHex: nil)

    #expect(color == ForumColors.brownPrimary)
}

// MARK: - Test support

/// An sRGB triple resolved out of a `Color` for one interface style, with the
/// WCAG contrast math restated independently of the production code.
private struct TestRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(_ color: Color, _ style: UIUserInterfaceStyle) {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.red = Double(red)
        self.green = Double(green)
        self.blue = Double(blue)
    }

    func contrast(with other: TestRGB) -> Double {
        let brighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Resolved `UIColor` components round-trip through 8-bit storage, so
    /// equality is per-channel within half a step.
    static func == (lhs: TestRGB, rhs: TestRGB) -> Bool {
        abs(lhs.red - rhs.red) < 0.002
            && abs(lhs.green - rhs.green) < 0.002
            && abs(lhs.blue - rhs.blue) < 0.002
    }
}

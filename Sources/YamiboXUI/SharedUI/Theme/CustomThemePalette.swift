import Foundation

extension ForumThemePalette {
    static func customSwitchTint(hex: UInt32) -> UInt32 {
        // Switch thumbs stay white in both appearances. Keep the track visible
        // against both the thumb and a dark settings surface, even for white/black seeds.
        ThemeSeedColor(hex: hex).adjusted(toward: ThemeSeedColor(hex: 0x767676)) {
            $0.contrast(with: ThemeSeedColor(hex: 0xFFFFFF)) >= 3
                && $0.contrast(with: ThemeSeedColor(hex: 0x1C1C1E)) >= 3
        }.hex
    }

    static func custom(hex: UInt32) -> Self {
        let seed = ThemeSeedColor(hex: hex)
        return Self(
            id: "custom-\(seed.hex)",
            usesColoredNavigationBar: true,
            light: customScheme(seed: seed, isDark: false),
            dark: customScheme(seed: seed, isDark: true)
        )
    }

    private static func customScheme(seed: ThemeSeedColor, isDark: Bool) -> Scheme {
        let white = ThemeSeedColor(hex: 0xFFFFFF)
        let black = ThemeSeedColor(hex: 0x000000)
        let neutralPage = ThemeSeedColor(hex: isDark ? 0x111214 : 0xF2F2F7)
        let neutralSurface = ThemeSeedColor(hex: isDark ? 0x1C1D20 : 0xFFFFFF)
        let page = (isDark ? neutralPage : white).mixed(with: seed, amount: 0.08)
        let surface = neutralSurface.mixed(with: seed, amount: isDark ? 0.06 : 0.025)
        let baseSurfaces = [page, surface, neutralPage, neutralSurface]
        let textEndpoint = isDark ? white : black

        // Existing prominent panels and navigation bars use white foregrounds.
        let toolbar = seed.adjusted(toward: black) { $0.contrast(with: white) >= 7 }
        let prominent = isDark ? toolbar.mixed(with: black, amount: 0.2) : toolbar

        // Leave headroom for highlighted rows as well as uncolored surfaces.
        // Mixing toward black/white preserves the seed's hue, including gray.
        let accentText = seed.adjusted(toward: textEndpoint) { candidate in
            baseSurfaces.allSatisfy { candidate.contrast(with: $0) >= 7 }
                && candidate.contrast(with: surface.mixed(with: candidate, amount: 0.22)) >= 4.5
                // Colored toolbars resolve the dark accent even in light mode.
                && (!isDark || candidate.contrast(with: toolbar) >= 4.5)
        }
        let textSurfaces = baseSurfaces + [surface.mixed(with: accentText, amount: 0.22)]
        func readableText(_ hex: UInt32) -> UInt32 {
            ThemeSeedColor(hex: hex).adjusted(toward: textEndpoint) { candidate in
                textSurfaces.allSatisfy { candidate.contrast(with: $0) >= 4.5 }
            }.hex
        }

        let primaryText = readableText(isDark ? 0xF2F2F4 : 0x1C1C1E)

        return Scheme(
            pageBackground: page.hex,
            surface: surface.hex,
            primaryText: primaryText,
            secondaryText: readableText(isDark ? 0xC2C3C8 : 0x4A4A50),
            tertiaryText: readableText(isDark ? 0xA9AAB0 : 0x5F6068),
            accent: prominent.hex,
            accentText: accentText.hex,
            supportingText: accentText.hex,
            actionText: accentText.hex,
            decoration: accentText.hex,
            progressFill: accentText.hex,
            decorativeFill: prominent.hex,
            prominentSurface: prominent.hex,
            surfaceTint: accentText.hex,
            navigationTint: accentText.hex,
            pinnedBadgeTint: accentText.hex,
            webText: primaryText,
            navigationBarBackground: prominent.hex,
            // State colors remain semantic, not derived from the chosen seed.
            warning: isDark ? 0xF5B957 : 0x8A4B00,
            warningFill: isDark ? 0x6B430D : 0xF5C451,
            danger: isDark ? 0xFF8478 : 0xB42318,
            dangerFill: isDark ? 0x9E2B2B : 0xB42318
        )
    }
}

private struct ThemeSeedColor {
    let hex: UInt32

    private func channel(_ shift: UInt32) -> Double {
        Double((hex >> shift) & 0xFF) / 255
    }

    func mixed(with other: Self, amount: Double) -> Self {
        func component(_ shift: UInt32) -> UInt32 {
            let value = channel(shift) * (1 - amount) + other.channel(shift) * amount
            return UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        return Self(hex: (component(16) << 16) | (component(8) << 8) | component(0))
    }

    private var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(channel(16)) + 0.7152 * linear(channel(8)) + 0.0722 * linear(channel(0))
    }

    func contrast(with other: Self) -> Double {
        let first = luminance
        let second = other.luminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Find the smallest adjustment that passes after 8-bit quantization.
    func adjusted(toward endpoint: Self, isReadable: (Self) -> Bool) -> Self {
        guard !isReadable(self) else { return self }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<20 {
            let amount = (lower + upper) / 2
            if isReadable(mixed(with: endpoint, amount: amount)) {
                upper = amount
            } else {
                lower = amount
            }
        }
        return mixed(with: endpoint, amount: upper)
    }
}

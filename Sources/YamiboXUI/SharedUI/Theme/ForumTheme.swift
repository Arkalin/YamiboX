import SwiftUI
import YamiboXCore

/// Semantic colors for native forum surfaces. The application theme selects a
/// palette, while reader surfaces keep their own background and semantic
/// comment colors.
// `Color` is immutable but is not declared Sendable by SwiftUI. A theme only
// stores immutable values, so crossing the app's UI-bound settings boundary is
// safe without forcing the entire theme-selection interface onto MainActor.
public struct ForumTheme: @unchecked Sendable {
    public let id: String
    public let accent: Color
    public let accentText: Color
    /// Non-interactive labels, separate from actions and decoration.
    public let supportingText: Color
    /// Inline links and understated actions; `accentText` remains the control tint.
    public let actionText: Color
    /// Non-interactive icons and quote rules, not text or progress indicators.
    public let decoration: Color
    public let progressFill: Color
    /// Decorative background washes and shadows.
    public let decorativeFill: Color
    /// High-contrast panels paired with white labels in every appearance.
    public let prominentSurface: Color
    public let usesColoredNavigationBar: Bool
    public let divider: Color
    public let pageBackground: Color
    public let surface: Color
    public let primaryText: Color
    public let webText: Color
    public let secondaryText: Color
    public let tertiaryText: Color
    public let border: Color
    public let mutedFill: Color
    public let selectedFill: Color
    public let warning: Color
    public let warningFill: Color
    public let danger: Color
    public let dangerFill: Color
    public let pinnedSurface: Color
    public let announcementSurface: Color
    public let navigationSurface: Color
    /// Fixed colors, not adaptive: `toolbarColorScheme(.dark)` makes the
    /// toolbar resolve adaptive colors against dark traits even in light mode.
    public let navigationBarBackgroundLight: Color
    public let navigationBarBackgroundDark: Color

    public let pinnedBadgeFill: Color

    public init(
        id: String,
        accent: Color,
        accentText: Color,
        supportingText: Color,
        actionText: Color,
        decoration: Color,
        progressFill: Color,
        decorativeFill: Color,
        prominentSurface: Color,
        usesColoredNavigationBar: Bool,
        pinnedBadgeFill: Color,
        divider: Color,
        pageBackground: Color,
        surface: Color,
        primaryText: Color,
        webText: Color,
        secondaryText: Color,
        tertiaryText: Color,
        border: Color,
        mutedFill: Color,
        selectedFill: Color,
        warning: Color,
        danger: Color,
        pinnedSurface: Color,
        announcementSurface: Color,
        navigationSurface: Color,
        navigationBarBackgroundLight: Color,
        navigationBarBackgroundDark: Color,
        warningFill: Color? = nil,
        dangerFill: Color? = nil
    ) {
        self.id = id
        self.accent = accent
        self.accentText = accentText
        self.supportingText = supportingText
        self.actionText = actionText
        self.decoration = decoration
        self.progressFill = progressFill
        self.decorativeFill = decorativeFill
        self.prominentSurface = prominentSurface
        self.usesColoredNavigationBar = usesColoredNavigationBar
        self.pinnedBadgeFill = pinnedBadgeFill
        self.divider = divider
        self.pageBackground = pageBackground
        self.surface = surface
        self.primaryText = primaryText
        self.webText = webText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.border = border
        self.mutedFill = mutedFill
        self.selectedFill = selectedFill
        self.warning = warning
        self.warningFill = warningFill ?? warning
        self.danger = danger
        self.dangerFill = dangerFill ?? danger
        self.pinnedSurface = pinnedSurface
        self.announcementSurface = announcementSurface
        self.navigationSurface = navigationSurface
        self.navigationBarBackgroundLight = navigationBarBackgroundLight
        self.navigationBarBackgroundDark = navigationBarBackgroundDark
    }

    // Neutral surfaces for themes with interface tinting disabled, not a selectable theme.
    private static let neutralSurfaces = ForumThemePalette(
        id: "neutral-surfaces",
        usesColoredNavigationBar: false,
        light: .init(
            pageBackground: 0xF2F2F7, surface: 0xFFFFFF,
            primaryText: 0x1C1C1E, secondaryText: 0x4A4A50, tertiaryText: 0x5F6068,
            accent: 0x4E2A1B, accentText: 0x4E2A1B,
            supportingText: 0x5F6067, actionText: 0x6D3A2B,
            decoration: 0x5F6067, progressFill: 0x5F6067,
            decorativeFill: 0x5F6067, prominentSurface: 0x4E2A1B,
            surfaceTint: 0x5F6067, navigationTint: 0x5F6067, pinnedBadgeTint: 0x4E2A1B,
            webText: 0x34343A, navigationBarBackground: 0xF2F2F7,
            warning: 0x8A4B00, warningFill: 0xF5C451,
            danger: 0xB42318, dangerFill: 0xB42318
        ),
        dark: .init(
            pageBackground: 0x111214, surface: 0x1C1D20,
            primaryText: 0xF2F2F4, secondaryText: 0xC2C3C8, tertiaryText: 0xA9AAB0,
            accent: 0x24120C, accentText: 0xD6A083,
            supportingText: 0xB0B0B5, actionText: 0xD6A083,
            decoration: 0xB0B0B5, progressFill: 0xB0B0B5,
            decorativeFill: 0xB0B0B5, prominentSurface: 0x24120C,
            surfaceTint: 0xB0B0B5, navigationTint: 0xB0B0B5, pinnedBadgeTint: 0xD6A083,
            webText: 0xE5E5EA, navigationBarBackground: 0x111214,
            warning: 0xF5B957, warningFill: 0x6B430D,
            danger: 0xFF8478, dangerFill: 0x9E2B2B
        )
    ).theme

    public static let classic = ForumThemePalette(
        id: AppThemePreset.classic.rawValue,
        usesColoredNavigationBar: true,
        light: .init(
            pageBackground: 0xFFF3D6, surface: 0xFFF7E0,
            primaryText: 0x2E1A0E, secondaryText: 0x6E5345, tertiaryText: 0x6D5440,
            accent: 0x4E2A1B, accentText: 0x4E2A1B,
            supportingText: 0x6D3A2B, actionText: 0x6D3A2B,
            decoration: 0x6D3A2B, progressFill: 0x6D3A2B,
            decorativeFill: 0x4E2A1B, prominentSurface: 0x4E2A1B,
            surfaceTint: 0x6D3A2B, navigationTint: 0x4E2A1B, pinnedBadgeTint: 0x4E2A1B,
            webText: 0x6E2B19, navigationBarBackground: 0x4E2A1B,
            warning: 0x834700, warningFill: 0xF5C451,
            danger: 0xA61B29, dangerFill: 0xA61B29
        ),
        dark: .init(
            pageBackground: 0x17110D, surface: 0x241B15,
            primaryText: 0xF4E7D1, secondaryText: 0xC59F8A, tertiaryText: 0xC69D89,
            accent: 0x24120C, accentText: 0xD6A083,
            supportingText: 0xD6A083, actionText: 0xD6A083,
            decoration: 0xD6A083, progressFill: 0xD6A083,
            decorativeFill: 0x24120C, prominentSurface: 0x24120C,
            surfaceTint: 0xD6A083, navigationTint: 0xD6A083, pinnedBadgeTint: 0xD6A083,
            webText: 0xF0D8BC, navigationBarBackground: 0x24120C,
            warning: 0xF4B35E, warningFill: 0x66400D,
            danger: 0xFF8C83, dangerFill: 0x9C2830
        )
    ).theme

    public static func theme(for preset: AppThemePreset) -> ForumTheme {
        switch preset {
        case .classic: classic
        case .custom: ForumThemePalette.custom(hex: AppAppearanceSettings.defaultCustomThemeColorHex).theme
        }
    }

    public static func theme(for settings: AppAppearanceSettings) -> ForumTheme {
        let palette = settings.themePreset == .custom
            ? ForumThemePalette.custom(hex: settings.customThemeColorHex).theme
            : theme(for: settings.themePreset)
        let surfaces = settings.usesAccentSurfaces ? palette : neutralSurfaces
        // Rich-text renderers cache by theme ID, including the surface style.
        let id = "\(palette.id)-\(settings.usesAccentSurfaces)"
        return ForumTheme(
            id: id,
            accent: palette.accent,
            accentText: palette.accentText,
            supportingText: surfaces.supportingText,
            actionText: palette.actionText,
            decoration: surfaces.decoration,
            progressFill: surfaces.progressFill,
            decorativeFill: surfaces.decorativeFill,
            prominentSurface: palette.prominentSurface,
            usesColoredNavigationBar: settings.usesAccentSurfaces,
            pinnedBadgeFill: settings.usesAccentSurfaces ? palette.pinnedBadgeFill : palette.accentText.opacity(0.16),
            divider: surfaces.divider,
            pageBackground: surfaces.pageBackground,
            surface: surfaces.surface,
            primaryText: surfaces.primaryText,
            webText: surfaces.webText,
            secondaryText: surfaces.secondaryText,
            tertiaryText: surfaces.tertiaryText,
            border: surfaces.border,
            mutedFill: surfaces.mutedFill,
            selectedFill: settings.usesAccentSurfaces ? palette.selectedFill : palette.accentText.opacity(0.16),
            warning: surfaces.warning,
            danger: surfaces.danger,
            pinnedSurface: surfaces.pinnedSurface,
            announcementSurface: surfaces.announcementSurface,
            navigationSurface: surfaces.navigationSurface,
            navigationBarBackgroundLight: surfaces.navigationBarBackgroundLight,
            navigationBarBackgroundDark: surfaces.navigationBarBackgroundDark,
            warningFill: surfaces.warningFill,
            dangerFill: surfaces.dangerFill
        )
    }
}

struct ForumThemePalette {
    let id: String
    let usesColoredNavigationBar: Bool
    let light: Scheme
    let dark: Scheme

    struct Scheme {
        let pageBackground: UInt32
        let surface: UInt32
        let primaryText: UInt32
        let secondaryText: UInt32
        let tertiaryText: UInt32
        let accent: UInt32
        let accentText: UInt32
        let supportingText: UInt32
        let actionText: UInt32
        let decoration: UInt32
        let progressFill: UInt32
        let decorativeFill: UInt32
        let prominentSurface: UInt32
        // Non-selected surface washes have their own tint seeds.
        let surfaceTint: UInt32
        let navigationTint: UInt32
        let pinnedBadgeTint: UInt32
        let webText: UInt32
        let navigationBarBackground: UInt32
        let warning: UInt32
        let warningFill: UInt32
        let danger: UInt32
        let dangerFill: UInt32

        var divider: UInt32 { surface.mixed(with: primaryText, amount: 0.18) }
        var border: UInt32 { surface.mixed(with: primaryText, amount: 0.12) }
        var mutedFill: UInt32 { surface.mixed(with: surfaceTint, amount: 0.10) }
        var selectedFill: UInt32 { surface.mixed(with: accentText, amount: 0.16) }
        // Pinned rows are a navigation treatment, not a warning state. Keep
        // their highlight in the selected palette so they do not retain the
        // old brown warning tone when the app theme changes.
        var pinnedSurface: UInt32 { surface.mixed(with: surfaceTint, amount: 0.12) }
        var announcementSurface: UInt32 { surface.mixed(with: surfaceTint, amount: 0.22) }
        var navigationSurface: UInt32 { surface.mixed(with: navigationTint, amount: 0.10) }
        var pinnedBadgeFill: UInt32 { surface.mixed(with: pinnedBadgeTint, amount: 0.16) }
    }

    var theme: ForumTheme {
        ForumTheme(
            id: id,
            accent: adaptive(\.accent),
            accentText: adaptive(\.accentText),
            supportingText: adaptive(\.supportingText),
            actionText: adaptive(\.actionText),
            decoration: adaptive(\.decoration),
            progressFill: adaptive(\.progressFill),
            decorativeFill: adaptive(\.decorativeFill),
            prominentSurface: adaptive(\.prominentSurface),
            usesColoredNavigationBar: usesColoredNavigationBar,
            pinnedBadgeFill: adaptive(\.pinnedBadgeFill),
            divider: adaptive(\.divider),
            pageBackground: adaptive(\.pageBackground),
            surface: adaptive(\.surface),
            primaryText: adaptive(\.primaryText),
            webText: adaptive(\.webText),
            secondaryText: adaptive(\.secondaryText),
            tertiaryText: adaptive(\.tertiaryText),
            border: adaptive(\.border),
            mutedFill: adaptive(\.mutedFill),
            selectedFill: adaptive(\.selectedFill),
            warning: adaptive(\.warning),
            danger: adaptive(\.danger),
            pinnedSurface: adaptive(\.pinnedSurface),
            announcementSurface: adaptive(\.announcementSurface),
            navigationSurface: adaptive(\.navigationSurface),
            navigationBarBackgroundLight: Color(hex: light.navigationBarBackground),
            navigationBarBackgroundDark: Color(hex: dark.navigationBarBackground),
            warningFill: adaptive(\.warningFill),
            dangerFill: adaptive(\.dangerFill)
        )
    }

    private func adaptive(_ keyPath: KeyPath<Scheme, UInt32>) -> Color {
        Color(light: light[keyPath: keyPath], dark: dark[keyPath: keyPath])
    }
}

private extension UInt32 {
    func mixed(with other: UInt32, amount: Double) -> UInt32 {
        let clamped = Swift.min(Swift.max(amount, 0), 1)
        func channel(_ shift: UInt32) -> UInt32 {
            let start = Double((self >> shift) & 0xFF)
            let end = Double((other >> shift) & 0xFF)
            return UInt32((start + (end - start) * clamped).rounded())
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}

private struct ForumThemeKey: EnvironmentKey {
    static let defaultValue = ForumTheme.classic
}

extension EnvironmentValues {
    var forumTheme: ForumTheme {
        get { self[ForumThemeKey.self] }
        set { self[ForumThemeKey.self] = newValue }
    }
}

extension View {
    func forumTheme(_ theme: ForumTheme) -> some View {
        environment(\.forumTheme, theme)
            .tint(theme.accentText)
    }

    func forumPageBackground() -> some View {
        modifier(ForumPageBackgroundModifier())
    }

    func forumNavigationBarStyle() -> some View {
        modifier(ForumNavigationBarStyleModifier())
    }

    func forumCardBackground(cornerRadius: CGFloat = 8, fill: Color? = nil) -> some View {
        modifier(ForumCardBackgroundModifier(cornerRadius: cornerRadius, fill: fill))
    }
}

private struct ForumPageBackgroundModifier: ViewModifier {
    @Environment(\.forumTheme) private var theme

    func body(content: Content) -> some View {
        content.background(theme.pageBackground.ignoresSafeArea())
    }
}

private struct ForumCardBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fill: Color?
    @Environment(\.forumTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(fill ?? theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
    }
}

private struct ForumNavigationBarStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.forumTheme) private var theme

    func body(content: Content) -> some View {
        content
            .toolbarBackground(theme.navigationBarBackground(for: colorScheme), for: .navigationBar)
            .toolbarBackground(theme.usesColoredNavigationBar ? .visible : .hidden, for: .navigationBar)
            .toolbarColorScheme(theme.usesColoredNavigationBar ? .dark : nil, for: .navigationBar)
    }
}

extension ForumTheme {
    public func navigationBarBackground(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            navigationBarBackgroundDark
        default:
            navigationBarBackgroundLight
        }
    }
}

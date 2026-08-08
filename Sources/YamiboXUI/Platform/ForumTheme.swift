import SwiftUI

/// Semantic colors for native forum surfaces.
///
/// `classic` preserves the forum's existing brown presentation. Future forum
/// preferences only need to select another `ForumTheme` at the forum root;
/// readers intentionally have their own `ReaderTheme`.
// `Color` is immutable but is not declared Sendable by SwiftUI. A theme only
// stores immutable values, so crossing the app's UI-bound settings boundary is
// safe without forcing the entire theme-selection interface onto MainActor.
public struct ForumTheme: @unchecked Sendable {
    public let id: String
    public let accent: Color
    public let accentText: Color
    public let mutedAccent: Color
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
    public let danger: Color
    public let pinnedSurface: Color
    public let announcementSurface: Color
    public let navigationSurface: Color

    public init(
        id: String,
        accent: Color,
        accentText: Color,
        mutedAccent: Color,
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
        navigationSurface: Color
    ) {
        self.id = id
        self.accent = accent
        self.accentText = accentText
        self.mutedAccent = mutedAccent
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
        self.danger = danger
        self.pinnedSurface = pinnedSurface
        self.announcementSurface = announcementSurface
        self.navigationSurface = navigationSurface
    }

    public static let classic = ForumTheme(
        id: "classic",
        accent: Color(light: 0x4E2A1B, dark: 0x24120C),
        accentText: Color(light: 0x4E2A1B, dark: 0xD6A083),
        mutedAccent: Color(light: ForumThemeClassicMetrics.mutedAccentLightHex, dark: ForumThemeClassicMetrics.mutedAccentDarkHex),
        divider: Color(light: 0xCCB8A8, dark: 0x8F6F5E),
        pageBackground: Color(light: ForumThemeClassicMetrics.pageBackgroundLightHex, dark: 0x17110D),
        surface: Color(light: 0xFFF7E0, dark: ForumThemeClassicMetrics.surfaceDarkHex),
        primaryText: Color(light: ForumThemeClassicMetrics.primaryTextLightHex, dark: ForumThemeClassicMetrics.primaryTextDarkHex),
        webText: Color(light: 0x6E2B19, dark: 0xF0D8BC),
        secondaryText: Color(light: 0x7A5C4D, dark: 0xAE8C7A),
        tertiaryText: Color(light: 0x85674E, dark: 0xA1806F),
        border: Color(light: ForumThemeClassicMetrics.mutedAccentLightHex, dark: ForumThemeClassicMetrics.mutedAccentDarkHex).opacity(0.18),
        mutedFill: Color(light: ForumThemeClassicMetrics.mutedAccentLightHex, dark: ForumThemeClassicMetrics.mutedAccentDarkHex).opacity(0.10),
        selectedFill: Color(light: 0xF59E2A, dark: 0xF0A33A).opacity(0.15),
        warning: Color(light: 0xF59E2A, dark: 0xF0A33A),
        danger: Color(light: 0xA61B29, dark: 0xFF7A70),
        pinnedSurface: Color(light: 0xFFF0C8, dark: 0x302416),
        announcementSurface: Color(light: 0xFFE8B0, dark: 0x382711),
        navigationSurface: Color(light: 0xFFE6B7, dark: 0x21150F)
    )
}

/// Numeric values stay private to the classic renderer. They are used only
/// where authored HTML colors need contrast calculations, not by forum views.
enum ForumThemeClassicMetrics {
    static let mutedAccentLightHex: UInt32 = 0x6D3A2B
    static let mutedAccentDarkHex: UInt32 = 0xD6A083
    static let pageBackgroundLightHex: UInt32 = 0xFFF3D6
    static let surfaceDarkHex: UInt32 = 0x241B15
    static let primaryTextLightHex: UInt32 = 0x2E1A0E
    static let primaryTextDarkHex: UInt32 = 0xF4E7D1
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
            .tint(theme.accent)
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
            .toolbarBackground(navigationBarBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var navigationBarBackground: Color {
        colorScheme == .dark ? theme.accent : theme.navigationSurface
    }
}

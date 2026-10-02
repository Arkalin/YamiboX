import SwiftUI
import YamiboXCore

/// The application-wide accent paired with the full forum palette for a
/// selected appearance preset. Switches have a separate track tint.
public struct AppTheme: @unchecked Sendable {
    public let id: String
    public let controlAccent: Color
    public let switchTint: Color
    public let forumTheme: ForumTheme

    public init(id: String, controlAccent: Color, forumTheme: ForumTheme, switchTint: Color? = nil) {
        self.id = id
        self.controlAccent = controlAccent
        self.switchTint = switchTint ?? controlAccent
        self.forumTheme = forumTheme
    }

    public static func theme(for preset: AppThemePreset) -> AppTheme {
        theme(for: AppAppearanceSettings(themePreset: preset))
    }

    public static func theme(for settings: AppAppearanceSettings) -> AppTheme {
        let forumTheme = ForumTheme.theme(for: settings)
        return AppTheme(
            id: forumTheme.id,
            controlAccent: forumTheme.accentText,
            forumTheme: forumTheme,
            switchTint: settings.themePreset == .custom
                ? Color(hex: ForumThemePalette.customSwitchTint(hex: settings.customThemeColorHex))
                : nil
        )
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.theme(for: .classic)
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    func appTheme(_ theme: AppTheme) -> some View {
        environment(\.appTheme, theme)
            .environment(\.forumTheme, theme.forumTheme)
            .tint(theme.controlAccent)
    }
}

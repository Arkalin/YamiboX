import SwiftUI
import YamiboXCore

/// The application-wide accent paired with the full forum palette for a
/// selected appearance preset. Non-forum screens use only `controlAccent`.
public struct AppTheme: @unchecked Sendable {
    public let id: String
    public let controlAccent: Color
    public let forumTheme: ForumTheme

    public init(id: String, controlAccent: Color, forumTheme: ForumTheme) {
        self.id = id
        self.controlAccent = controlAccent
        self.forumTheme = forumTheme
    }

    public static func theme(for preset: AppThemePreset) -> AppTheme {
        let forumTheme = ForumTheme.theme(for: preset)
        return AppTheme(
            id: preset.rawValue,
            controlAccent: forumTheme.accentText,
            forumTheme: forumTheme
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

import Foundation

/// Palette rendering modes; user-visible themes live in `AppThemeLibrary`.
public enum AppThemePreset: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case classic
    case custom

    public var id: String { rawValue }

}

public enum AppDarkMode: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case system
    case off
    case on

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: L10n.string("settings.app_theme.dark_mode.system")
        case .off: L10n.string("settings.app_theme.dark_mode.off")
        case .on: L10n.string("settings.app_theme.dark_mode.on")
        }
    }
}

public struct AppAppearanceSettings: Codable, Hashable, Sendable {
    public static let defaultCustomThemeColorHex: UInt32 = 0x6750A4

    public var themeLibrary: AppThemeLibrary
    public var themePreset: AppThemePreset {
        guard let theme = themeLibrary.selectedTheme else { return .classic }
        return theme.isBuiltIn ? .classic : .custom
    }
    public var customThemeColorHex: UInt32 {
        themeLibrary.selectedTheme?.colorHex ?? Self.defaultCustomThemeColorHex
    }
    public var usesAccentSurfaces: Bool
    public var darkMode: AppDarkMode
    public var launchBackground: CustomBackgroundSettings
    public var launchShowsBrand: Bool

    public init(
        themePreset: AppThemePreset = .classic,
        customThemeColorHex: UInt32 = Self.defaultCustomThemeColorHex,
        themeLibrary: AppThemeLibrary? = nil,
        usesAccentSurfaces: Bool? = nil,
        darkMode: AppDarkMode = .system,
        launchBackground: CustomBackgroundSettings = .init(),
        launchShowsBrand: Bool = true
    ) {
        self.themeLibrary = themeLibrary ?? (themePreset == .custom
            ? AppThemeLibrary(themes: [AppThemeDefinition(id: "custom", name: L10n.string("settings.app_theme.custom"), colorHex: customThemeColorHex)], selectedID: "custom")
            : AppThemeLibrary())
        self.usesAccentSurfaces = usesAccentSurfaces ?? true
        self.darkMode = darkMode
        self.launchBackground = launchBackground
        self.launchShowsBrand = launchShowsBrand
    }

    private enum CodingKeys: String, CodingKey {
        case themeLibrary, usesAccentSurfaces, darkMode, launchBackground, launchShowsBrand
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            themeLibrary: try container.decodeIfPresent(AppThemeLibrary.self, forKey: .themeLibrary) ?? AppThemeLibrary(),
            usesAccentSurfaces: try container.decodeIfPresent(Bool.self, forKey: .usesAccentSurfaces) ?? true,
            darkMode: try container.decodeIfPresent(AppDarkMode.self, forKey: .darkMode) ?? .system,
            launchBackground: try container.decodeIfPresent(CustomBackgroundSettings.self, forKey: .launchBackground) ?? .init(),
            launchShowsBrand: try container.decodeIfPresent(Bool.self, forKey: .launchShowsBrand) ?? true
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(themeLibrary, forKey: .themeLibrary)
        try container.encode(usesAccentSurfaces, forKey: .usesAccentSurfaces)
        try container.encode(darkMode, forKey: .darkMode)
        try container.encode(launchBackground, forKey: .launchBackground)
        try container.encode(launchShowsBrand, forKey: .launchShowsBrand)
    }
}

import Foundation

/// Built-in appearance choices for the application and its forum surfaces.
public enum AppThemePreset: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case standard
    case classic
    case teal
    case rose

    public var id: String { rawValue }
}

public struct AppAppearanceSettings: Codable, Hashable, Sendable {
    public var themePreset: AppThemePreset

    public init(themePreset: AppThemePreset = .classic) {
        self.themePreset = themePreset
    }
}

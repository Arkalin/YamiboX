import Foundation

/// Built-in color palettes for every forum surface.
public enum ForumThemePreset: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case standard
    case classic
    case teal
    case rose

    public var id: String { rawValue }
}

public struct ForumAppearanceSettings: Codable, Hashable, Sendable {
    public var themePreset: ForumThemePreset

    public init(themePreset: ForumThemePreset = .classic) {
        self.themePreset = themePreset
    }
}

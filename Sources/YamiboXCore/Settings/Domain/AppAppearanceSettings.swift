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
    public var launchBackground: CustomBackgroundSettings
    public var launchShowsBrand: Bool

    public init(themePreset: AppThemePreset = .classic, launchBackground: CustomBackgroundSettings = .init(), launchShowsBrand: Bool = true) {
        self.themePreset = themePreset
        self.launchBackground = launchBackground
        self.launchShowsBrand = launchShowsBrand
    }

    private enum CodingKeys: String, CodingKey { case themePreset, launchBackground, launchShowsBrand }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            themePreset: try container.decode(AppThemePreset.self, forKey: .themePreset),
            launchBackground: try container.decodeIfPresent(CustomBackgroundSettings.self, forKey: .launchBackground) ?? .init(),
            launchShowsBrand: try container.decodeIfPresent(Bool.self, forKey: .launchShowsBrand) ?? true
        )
    }
}

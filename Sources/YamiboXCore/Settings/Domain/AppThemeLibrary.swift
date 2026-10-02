import Foundation

public struct AppThemeDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var colorHex: UInt32
    public var isBuiltIn: Bool { id == "classic" }

    public init(id: String = UUID().uuidString, name: String, colorHex: UInt32) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    public static var classic: Self {
        Self(id: "classic", name: L10n.string("settings.app_theme.classic"), colorHex: 0x4E2A1B)
    }

    public var normalized: Self {
        var result = self
        result.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if result.name.isEmpty { result.name = L10n.string("settings.app_theme.untitled") }
        if colorHex > 0xFFFFFF { result.colorHex = AppAppearanceSettings.defaultCustomThemeColorHex }
        return result
    }
}

/// Membership and selection travel together so deleting the active theme is atomic.
public struct AppThemeLibrary: Codable, Hashable, Sendable {
    public private(set) var themes: [AppThemeDefinition]
    public private(set) var selectedID: String?

    public var selectedTheme: AppThemeDefinition? { themes.first { $0.id == selectedID } }

    public init(themes: [AppThemeDefinition] = [.classic], selectedID: String? = "classic") {
        var seen = Set<String>()
        self.themes = [.classic] + themes.filter { !$0.isBuiltIn && seen.insert($0.id).inserted }.map(\.normalized)
        self.selectedID = self.themes.first { $0.id == selectedID }?.id ?? self.themes.first?.id
    }

    public mutating func select(_ id: String) {
        guard themes.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    public mutating func save(_ theme: AppThemeDefinition) {
        guard !theme.isBuiltIn else { return }
        if let index = themes.firstIndex(where: { $0.id == theme.id }) {
            themes[index] = theme.normalized
        } else {
            themes.append(theme.normalized)
        }
        selectedID = theme.id
    }

    public mutating func remove(_ id: String) {
        guard id != "classic" else { return }
        themes.removeAll { $0.id == id }
        if selectedID == id { selectedID = "classic" }
    }

    private enum CodingKeys: String, CodingKey { case themes, selectedID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            themes: try container.decode([AppThemeDefinition].self, forKey: .themes),
            selectedID: try container.decodeIfPresent(String.self, forKey: .selectedID)
        )
    }
}

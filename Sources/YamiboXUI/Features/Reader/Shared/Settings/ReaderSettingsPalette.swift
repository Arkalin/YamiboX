import SwiftUI

#if os(iOS)

protocol ReaderSettingsPalette {
    var primaryText: Color { get }
    var secondaryText: Color { get }
    var cardBackground: Color { get }
    var segmentedBackground: Color { get }
    var divider: Color { get }
    var sectionStroke: Color { get }
    var selectedControlBackground: Color { get }
    var selectedControlText: Color { get }
}

enum ReaderSettingsPaletteTokens {
    static let darkPrimaryText = Color.white.opacity(0.92)

    static func divider(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    static func selectedControlText(isDark: Bool) -> Color {
        isDark ? .black.opacity(0.82) : .white
    }
}

#endif

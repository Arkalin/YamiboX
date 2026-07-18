import SwiftUI

#if os(iOS)

/// Palette surface consumed by the shared reader-settings components.
///
/// Manga and Novel keep their own concrete palette types because most colors
/// are *computed* differently (Manga derives from the color scheme alone,
/// Novel additionally blends the selected reading-theme background), so the
/// two initializers cannot be merged. The shared controls only need this
/// common vocabulary; each palette maps its own values onto it.
protocol ReaderSettingsPalette {
    var primaryText: Color { get }
    var secondaryText: Color { get }
    var cardBackground: Color { get }
    var segmentedBackground: Color { get }
    var divider: Color { get }
    /// Stroke around a settings card. Manga strokes with its dedicated
    /// `cardStroke` (slightly stronger than its divider in dark mode), Novel
    /// reuses its `divider` — a real per-side difference that the protocol
    /// preserves instead of forcing one value.
    var sectionStroke: Color { get }
    /// Fill of a selected chip in the mode/direction pickers. Manga uses the
    /// app accent, Novel uses its warm confirm-button blend — semantically
    /// different colors, so they are mapped, not merged.
    var selectedControlBackground: Color { get }
    /// Text/icon color painted on top of `selectedControlBackground`.
    var selectedControlText: Color { get }
}

/// Color literals that were duplicated verbatim between
/// `MangaReaderSettingsPalette` and `NovelReaderSheetPalette`.
///
/// Only values that are byte-identical on both sides live here; colors that
/// genuinely diverge (light-mode primary text, secondary-text opacities
/// 0.66 vs 0.68, all surface colors) stay in their respective palette.
enum ReaderSettingsPaletteTokens {
    /// Primary text on dark settings sheets (identical in both readers).
    static let darkPrimaryText = Color.white.opacity(0.92)

    /// Hairline used for row dividers (identical in both readers).
    static func divider(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    /// Warm brown blend behind the confirm button (and, on the Novel side,
    /// selected picker chips). Both readers blend the same target color by
    /// the same amount into their own base surface, which is why the base is
    /// a parameter.
    static func confirmButtonBackground(blendingInto base: Color, isDark: Bool) -> Color {
        isDark
            ? base.mix(with: Color(red: 0.44, green: 0.39, blue: 0.30), amount: 0.58)
            : base.mix(with: Color(red: 0.31, green: 0.26, blue: 0.18), amount: 0.72)
    }
}

#endif

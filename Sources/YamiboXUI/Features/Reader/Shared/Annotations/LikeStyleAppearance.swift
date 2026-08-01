import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

/// How each `LikeStyle` paints, in one place, so the body-text draw pass, the
/// style capsule's dots and the panel's colour bar can never drift apart.
///
/// Every colour is a system dynamic colour: the reader has six page themes and
/// an automatic dark mode, and a hard-coded RGB would eventually land on a
/// background it cannot be read against.
enum LikeStyleAppearance {
    /// Matches the alpha the reader has always drawn its (yellow-only)
    /// highlights at, so existing annotations look unchanged after migrating.
    static let fillAlpha: CGFloat = 0.28

    /// Underline thickness, in points. Two points survives a 1x downscale and
    /// still reads as a rule rather than a thin highlight.
    static let underlineThickness: CGFloat = 2

    /// How far above a line fragment's bottom edge the rule sits. Fragment
    /// rects come from `.standard` text segments, which include line leading,
    /// so drawing at `maxY` puts the rule in the gap below the glyphs and it
    /// reads as detached from the text it underlines.
    static let underlineBaselineInset: CGFloat = 3

    static func baseColor(for style: LikeStyle) -> UIColor {
        switch style {
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .pink: .systemPink
        case .purple: .systemPurple
        // Not the hard red Apple Books uses: `systemRed` already adapts to
        // light/dark, which is what "follows the theme" has to mean when the
        // page background is one of six themes.
        case .underline: .systemRed
        }
    }

    /// The colour actually painted into the text surface. Underline draws at
    /// full strength — it is a thin rule, so the wash alpha would make it
    /// vanish.
    static func paintColor(for style: LikeStyle) -> UIColor {
        style.isUnderline ? baseColor(for: style) : baseColor(for: style).withAlphaComponent(fillAlpha)
    }

    /// The rect to fill for one line fragment of an annotation. A colour fills
    /// the fragment (slightly outset so adjacent lines meet); an underline
    /// fills only a rule along its bottom edge.
    static func paintedRect(for style: LikeStyle, in fragment: CGRect) -> CGRect {
        guard style.isUnderline else {
            return fragment.insetBy(dx: -1, dy: -1)
        }
        return CGRect(
            x: fragment.minX,
            y: fragment.maxY - underlineBaselineInset - underlineThickness,
            width: fragment.width,
            height: underlineThickness
        )
    }

    /// The "this annotation has a note" badge, Apple Books style: a rounded
    /// square ring in the annotation's colour with a paper-coloured centre,
    /// straddling the top-leading corner of the highlight's first character.
    ///
    /// A ring rather than the solid dot this used to be: a solid chip in the
    /// annotation's own colour sits on top of a wash of the same colour, which
    /// made it effectively invisible — the hollow centre is what buys contrast
    /// on every one of the six page themes without needing a second colour.
    ///
    /// Sized from the line, not fixed: the badge marks a character, so it has
    /// to keep its proportion to that character across the reader's whole
    /// font-size range, clamped so it never vanishes at footnote sizes nor
    /// swallows a word at accessibility sizes.
    static func noteBadgeSide(forLineHeight lineHeight: CGFloat) -> CGFloat {
        min(max(lineHeight * 0.30, 9), 18)
    }

    static func noteBadgeRingWidth(forSide side: CGFloat) -> CGFloat {
        max(side * 0.24, 2)
    }

    static func noteBadgeCornerRadius(forSide side: CGFloat) -> CGFloat {
        side * 0.32
    }

    /// Straddles the fragment's leading edge horizontally, but hangs fully
    /// inside it vertically (top flush with the fragment top): `.standard`
    /// fragments carry their line leading, so the fragment top already sits
    /// above the ink, and "flush with fragment top" is what visually straddles
    /// the glyph corner the way Apple Books' badge does — centring on the
    /// fragment corner instead floats the badge into the line gap above.
    static func noteBadgeRect(anchoredTo firstFragment: CGRect) -> CGRect {
        let side = noteBadgeSide(forLineHeight: firstFragment.height)
        return CGRect(
            x: firstFragment.minX - side / 2,
            y: firstFragment.minY,
            width: side,
            height: side
        )
    }

    /// Swatch colour for the style capsule's dots and the panel's colour bar:
    /// full strength, since a 28%-alpha dot on a panel background would be
    /// almost invisible.
    static func swatchColor(for style: LikeStyle) -> Color {
        Color(baseColor(for: style))
    }

    /// One list line with the annotation's mark painted inline, the way Apple
    /// Books renders its highlight rows: the clause context around the excerpt
    /// (when the item has it) renders plain, and the excerpt itself carries the
    /// same wash — or underline — the reader paints on the page, so the row is
    /// a miniature of the annotation rather than a swatch next to plain text.
    static func inlineExcerptLine(for item: LikeItem) -> AttributedString {
        var line = AttributedString()
        if let prefix = item.excerptPrefix {
            line += AttributedString(prefix)
        }
        var excerpt = AttributedString(singleLine(item.excerptText ?? ""))
        if item.style.isUnderline {
            excerpt.underlineStyle = Text.LineStyle(
                pattern: .solid,
                color: Color(baseColor(for: .underline))
            )
        } else {
            excerpt.backgroundColor = Color(paintColor(for: item.style))
        }
        line += excerpt
        if let suffix = item.excerptSuffix {
            line += AttributedString(suffix)
        }
        return line
    }

    /// The row is a single line, so a selection that spanned paragraphs must
    /// not carry its newlines in — `lineLimit(1)` would truncate at the first
    /// one and show almost nothing.
    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
#endif

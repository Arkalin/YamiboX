import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

enum LikeStyleAppearance {
    static let fillAlpha: CGFloat = 0.28

    static let underlineThickness: CGFloat = 2

    static let underlineBaselineInset: CGFloat = 3

    static func baseColor(for style: LikeStyle) -> UIColor {
        switch style {
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .pink: .systemPink
        case .purple: .systemPurple
        case .underline: .systemRed
        }
    }

    static func paintColor(for style: LikeStyle) -> UIColor {
        style.isUnderline ? baseColor(for: style) : baseColor(for: style).withAlphaComponent(fillAlpha)
    }

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

    static func noteBadgeSide(forLineHeight lineHeight: CGFloat) -> CGFloat {
        min(max(lineHeight * 0.30, 9), 18)
    }

    static func noteBadgeRingWidth(forSide side: CGFloat) -> CGFloat {
        max(side * 0.24, 2)
    }

    static func noteBadgeCornerRadius(forSide side: CGFloat) -> CGFloat {
        side * 0.32
    }

    static func noteBadgeRect(anchoredTo firstFragment: CGRect) -> CGRect {
        let side = noteBadgeSide(forLineHeight: firstFragment.height)
        return CGRect(
            x: firstFragment.minX - side / 2,
            y: firstFragment.minY,
            width: side,
            height: side
        )
    }

    static func swatchColor(for style: LikeStyle) -> Color {
        Color(baseColor(for: style))
    }

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

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
#endif

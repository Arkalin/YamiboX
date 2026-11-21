import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
enum NovelLikeStyleMenu {
    static var styles: [LikeStyle] { LikeStyle.colors + [.underline] }

    private static let swatchSide: CGFloat = 22

    static func makeRoot(onSelect: @escaping (LikeStyle) -> Void) -> UIMenu {
        UIMenu(children: styles.map { style in
            UIAction(title: "", image: swatchImage(for: style)) { _ in
                onSelect(style)
            }
        })
    }

    static func swatchImage(for style: LikeStyle) -> UIImage {
        let side = swatchSide
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let color = LikeStyleAppearance.baseColor(for: style)
        let image = UIGraphicsImageRenderer(size: bounds.size).image { context in
            guard !style.isUnderline else {
                drawUnderlineGlyph(color: color, in: bounds)
                return
            }
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fillEllipse(in: bounds.insetBy(dx: 1, dy: 1))
        }
        let rendered = image.withRenderingMode(.alwaysOriginal)
        rendered.accessibilityLabel = L10n.string("likes.style.\(style.rawValue)")
        return rendered
    }

    private static func drawUnderlineGlyph(color: UIColor, in bounds: CGRect) {
        guard let glyph = UIImage(
            systemName: "underline",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: bounds.height * 0.72,
                weight: .semibold
            )
        )?.withTintColor(color, renderingMode: .alwaysOriginal) else {
            return
        }
        glyph.draw(in: CGRect(
            x: bounds.midX - glyph.size.width / 2,
            y: bounds.midY - glyph.size.height / 2,
            width: glyph.size.width,
            height: glyph.size.height
        ))
    }
}
#endif

import YamiboXCore

#if os(iOS)
import UIKit

/// The 「喜欢」 submenu: one row of style swatches, shared by both paths that
/// can set a style — capturing a new annotation and restyling an existing one.
///
/// Rendered by `UIEditMenuInteraction` as a horizontal bar of swatches, which
/// took three attempts to land and is worth recording so nobody re-litigates it:
///
/// - `preferredElementSize = .small` on the menu handed to an edit menu is
///   ignored outright; the root of an edit menu is always the classic bar.
/// - The bar renders an action's *image* only when the action has no title. An
///   action carrying both renders as text and drops the image silently, which
///   is what made the first attempt look like a list of colour names.
/// - A button-hosted `UIMenu` does honour `.small`, but a menu is a vertical
///   dropdown: it packs four icons into one row and then falls back to
///   full-width labelled rows. It cannot be a single strip.
///
/// - Only a menu's **root** renders as the bar. Handing these six back as a
///   submenu of the annotation menu drills into a vertical page instead, so the
///   row is presented as its own edit menu rather than nested under 「喜欢」.
///
/// The bar holds **six** items before it paginates behind a `›`. That ceiling is
/// why note and remove live in the menu that opens this one — six styles exactly
/// fills it, and a seventh would push a style onto a second page.
@MainActor
enum NovelLikeStyleMenu {
    /// The order the row lays out: the five colours, then underline.
    private static var styles: [LikeStyle] { LikeStyle.colors + [.underline] }

    /// Swatch side, in points. Sized against the bar rather than by taste: the
    /// bar gives every item the same slot regardless, so this only controls how
    /// much of that slot the colour fills.
    private static let swatchSide: CGFloat = 22

    /// The row, as the root of its own edit menu.
    static func makeRoot(onSelect: @escaping (LikeStyle) -> Void) -> UIMenu {
        UIMenu(children: styles.map { style in
            // No title, on purpose: the bar renders images only for title-less
            // actions. The accessible name rides on the image.
            UIAction(title: "", image: swatchImage(for: style)) { _ in
                onSelect(style)
            }
        })
    }

    /// Deliberately carries no "currently selected" ring. The bar is reached by
    /// opening 「喜欢」, so the style in force is one level up in context, and a
    /// ring heavy enough to read against six page themes drew the eye harder
    /// than the colours it was annotating.
    private static func swatchImage(for style: LikeStyle) -> UIImage {
        let side = swatchSide
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        // Resolved eagerly against the light appearance the menu's material
        // always uses, rather than the reader's own theme: the menu is a system
        // surface and does not inherit the page background.
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
        // `UIAction` exposes no accessibility label; the image's is the only
        // hook a title-less menu element leaves open.
        rendered.accessibilityLabel = L10n.string("likes.style.\(style.rawValue)")
        return rendered
    }

    /// A glyph rather than a dot: underline is a different kind of thing from a
    /// colour and has to read as one at a glance.
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

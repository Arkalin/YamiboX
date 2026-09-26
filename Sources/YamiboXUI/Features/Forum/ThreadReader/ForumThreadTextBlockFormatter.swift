import SwiftUI
import UIKit
import YamiboXCore

/// Maps a `ForumThreadTextBlock` (plain text + style runs + links + rubies)
/// to renderable SwiftUI values. Pure value transformation, no view state.
struct ForumThreadTextBlockFormatter {
    let block: ForumThreadTextBlock
    var theme: ForumTheme = .classic

    /// The whole block text with style runs and links applied.
    var attributedText: AttributedString {
        var attributed = AttributedString(block.text)
        let characterCount = block.text.count
        for run in block.styleRuns {
            guard let range = range(in: attributed, start: run.start, length: run.length, characterCount: characterCount) else {
                continue
            }
            attributed[range].font = font(for: run.style)
            attributed[range][ForumThreadItalicKey.self] = run.style.isItalic
            if let baseline = run.style.baseline, baseline != 0 {
                attributed[range][ForumThreadBaselineOffsetKey.self] = Double(baseline) * platformFont(for: run.style).pointSize * 0.45
            }
            let colors = ForumThreadAuthorColorAdapter.colors(for: run.style, theme: theme)
            if let foregroundColor = colors.foreground {
                attributed[range].foregroundColor = foregroundColor
            }
            if let backgroundColor = colors.background {
                attributed[range].backgroundColor = backgroundColor
            }
            if run.style.isUnderline {
                attributed[range].underlineStyle = .single
            }
            if run.style.isStrikethrough {
                attributed[range].strikethroughStyle = .single
            }
        }
        for link in block.links {
            guard let range = range(in: attributed, start: link.start, length: link.length, characterCount: characterCount) else {
                continue
            }
            attributed[range].link = link.url
            attributed[range].foregroundColor = ForumThreadAuthorColorAdapter.linkColor(
                onBackgroundHex: authoredBackgroundHex(under: link),
                theme: theme
            )
            attributed[range].underlineStyle = .single
        }
        for inline in block.inlineImages {
            guard let range = range(in: attributed, start: inline.start, length: 1, characterCount: characterCount),
                  String(attributed[range].characters) == "\u{FFFC}" else { continue }
            attributed[range][ForumThreadInlineImageKey.self] = inline.image
        }
        return attributed
    }

    /// The authored background a link is painted over, if any. A link inside a
    /// highlighted run needs a fixed color for the same reason the run's own
    /// text does — the scheme-adaptive link color is picked for the app's
    /// surfaces, not for the author's.
    private func authoredBackgroundHex(under link: ForumThreadTextLink) -> String? {
        block.styleRuns.first { run in
            run.style.backgroundHex != nil
                && run.start < link.start + link.length
                && link.start < run.start + run.length
        }?.style.backgroundHex
    }

    /// Paragraph metrics and ruby use one selectable TextKit text storage, not
    /// independently sized SwiftUI fragments. Offsets in the domain are graphemes.
    @MainActor
    func nativeText(images: [URL: UIImage], imageSize: CGFloat) -> NSAttributedString {
        let offsets = block.text.reduce(into: [0]) { offsets, character in
            offsets.append(offsets.last! + String(character).utf16.count)
        }
        func range(_ start: Int, _ length: Int) -> NSRange? {
            guard start >= 0, length > 0, start < offsets.count - 1 else { return nil }
            let end = min(start + length, offsets.count - 1)
            return NSRange(location: offsets[start], length: offsets[end] - offsets[start])
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = block.alignment == .center ? .center : block.alignment == .right ? .right : .left
        paragraph.lineSpacing = block.rubies.isEmpty ? 4 : UIFont.preferredFont(forTextStyle: .caption2).lineHeight + 2
        let font = platformFont(for: ForumThreadTextStyle())
        if let style = block.paragraphStyle {
            paragraph.firstLineHeadIndent = CGFloat(style.firstLineIndentEm ?? 0) * font.pointSize
                + UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(style.firstLineIndentPixels ?? 0))
            if let height = style.lineHeight {
                paragraph.minimumLineHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(min(height, 1_024)))
                paragraph.lineSpacing = block.rubies.isEmpty ? 0 : paragraph.lineSpacing
            }
            if let multiple = style.lineHeightMultiple {
                paragraph.lineHeightMultiple = CGFloat(min(max(multiple, 0.5), 10))
                paragraph.lineSpacing = block.rubies.isEmpty ? 0 : paragraph.lineSpacing
            }
        }
        let result = NSMutableAttributedString(string: block.text, attributes: [
            .font: font, .foregroundColor: UIColor(theme.primaryText), .paragraphStyle: paragraph
        ])
        for run in block.styleRuns {
            guard let range = range(run.start, run.length) else { continue }
            let font = platformFont(for: run.style, italic: run.style.isItalic)
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            let colors = ForumThreadAuthorColorAdapter.colors(for: run.style, theme: theme)
            if let color = colors.foreground { attributes[.foregroundColor] = UIColor(color) }
            if let color = colors.background { attributes[.backgroundColor] = UIColor(color) }
            if run.style.isUnderline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.isStrikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let baseline = run.style.baseline { attributes[.baselineOffset] = CGFloat(baseline) * font.pointSize * 0.45 }
            result.addAttributes(attributes, range: range)
        }
        for link in block.links {
            guard let range = range(link.start, link.length) else { continue }
            result.addAttributes([
                .link: link.url, .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: UIColor(ForumThreadAuthorColorAdapter.linkColor(onBackgroundHex: authoredBackgroundHex(under: link), theme: theme))
            ], range: range)
        }
        for ruby in block.rubies {
            guard let range = range(ruby.start, ruby.length) else { continue }
            result.addAttribute(.forumRuby, value: ForumThreadRubyAnnotation(text: ruby.rubyText, range: range), range: range)
        }
        for inline in block.inlineImages {
            guard let range = range(inline.start, 1), (result.string as NSString).substring(with: range) == "\u{FFFC}" else { continue }
            let attachment = NSTextAttachment()
            let source = images[inline.image.url] ?? UIImage(systemName: "face.smiling") ?? UIImage()
            attachment.image = ForumThreadInlineTextView.sizedUIImage(source, dimension: imageSize)
            attachment.bounds = CGRect(x: 0, y: -imageSize / 7, width: imageSize, height: imageSize)
            result.addAttribute(.attachment, value: attachment, range: range)
        }
        return result
    }

    private func range(
        in attributed: AttributedString,
        start: Int,
        length: Int,
        characterCount: Int
    ) -> Range<AttributedString.Index>? {
        guard start >= 0, start < characterCount else { return nil }
        let end = min(characterCount, start + length)
        guard end > start else { return nil }
        let startIndex = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let endIndex = attributed.index(attributed.startIndex, offsetByCharacters: end)
        return startIndex ..< endIndex
    }

    private func font(for style: ForumThreadTextStyle) -> Font {
        Font(platformFont(for: style))
    }

    private func platformFont(for style: ForumThreadTextStyle, italic: Bool = false) -> UIFont {
        // Styled runs must track Dynamic Type like the unstyled body text
        // around them, so the author-relative size is scaled through the
        // body text style's metrics instead of being frozen at 17pt.
        let baseSize = min(max(17 * (style.relativeFontSize ?? 1), 6), 256) * ((style.baseline ?? 0) == 0 ? 1 : 0.72)
        let scaledSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: baseSize)
        var font = UIFont.systemFont(ofSize: scaledSize)
        for family in (style.fontFamily ?? "").split(separator: ",") {
            let family = family.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let name = Self.fontAliases[family.lowercased()] ?? family
            if let selected = UIFont(name: name, size: scaledSize)
                ?? UIFont.fontNames(forFamilyName: name).first.flatMap({ UIFont(name: $0, size: scaledSize) }) {
                font = selected
                break
            }
        }
        if style.isBold, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
            font = UIFont(descriptor: descriptor, size: scaledSize)
        }
        if italic {
            font = UIFont(descriptor: font.fontDescriptor.withMatrix(CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)), size: scaledSize)
        }
        return font
    }

    private static let fontAliases = [
        "courier new": "CourierNewPSMT", "monospace": "Menlo-Regular",
        "times new roman": "TimesNewRomanPSMT", "serif": "TimesNewRomanPSMT",
        "arial": "ArialMT", "sans-serif": "Helvetica",
        "宋体": "Songti SC", "黑体": "PingFang SC", "微软雅黑": "PingFang SC", "楷体": "Kaiti SC"
    ]
}

/// Per-view-instance memoization of `ForumThreadTextBlockFormatter` output.
/// `ForumThreadTextBlockView` re-evaluates its `body` whenever
/// `ForumThreadReaderBodyView`'s `visiblePostIDs` changes during scrolling,
/// which would otherwise rebuild the `AttributedString` (an O(runs × n)
/// operation) for every visible text block on every scroll-triggered
/// visibility change. Held as `@State` in the view, so mutating this class's
/// stored properties updates the cache in place without itself triggering a
/// SwiftUI update.
final class ForumThreadTextBlockFormatterCache {
    private var cachedBlock: ForumThreadTextBlock?
    private var cachedThemeID: String?
    private var cachedAttributedText: AttributedString?
    private var cachedPointSize: CGFloat?
    private var cachedDynamicTypeSize: DynamicTypeSize?

    func attributedText(for block: ForumThreadTextBlock, theme: ForumTheme = .classic, dynamicTypeSize: DynamicTypeSize = .large) -> AttributedString {
        let pointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        if cachedBlock == block, cachedThemeID == theme.id, cachedPointSize == pointSize, cachedDynamicTypeSize == dynamicTypeSize, let cachedAttributedText {
            return cachedAttributedText
        }
        let attributedText = ForumThreadTextBlockFormatter(block: block, theme: theme).attributedText
        cachedBlock = block
        cachedThemeID = theme.id
        cachedPointSize = pointSize
        cachedDynamicTypeSize = dynamicTypeSize
        cachedAttributedText = attributedText
        return attributedText
    }
}

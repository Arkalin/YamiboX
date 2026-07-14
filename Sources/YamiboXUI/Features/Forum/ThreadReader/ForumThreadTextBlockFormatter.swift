import SwiftUI
import UIKit
import YamiboXCore

/// Maps a `ForumThreadTextBlock` (plain text + style runs + links + rubies)
/// to renderable SwiftUI values. Pure value transformation, no view state.
struct ForumThreadTextBlockFormatter {
    let block: ForumThreadTextBlock

    /// The whole block text with style runs and links applied.
    var attributedText: AttributedString {
        var attributed = AttributedString(block.text)
        let characterCount = block.text.count
        for run in block.styleRuns {
            guard let range = range(in: attributed, start: run.start, length: run.length, characterCount: characterCount) else {
                continue
            }
            attributed[range].font = font(for: run.style)
            if let foregroundColor = Color(forumThreadHex: run.style.foregroundHex) {
                attributed[range].foregroundColor = foregroundColor
            }
            if let backgroundColor = Color(forumThreadHex: run.style.backgroundHex) {
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
            attributed[range].foregroundColor = ForumColors.brownPrimary
            attributed[range].underlineStyle = .single
        }
        return attributed
    }

    /// The block split into ruby and plain segments, each carrying its slice
    /// of the styled text. The whole attributed text is built once and then
    /// sliced, so cost stays linear in the number of segments.
    var rubySegments: [ForumThreadRubySegment] {
        let attributed = attributedText
        let textCount = block.text.count
        let sortedRubies = block.rubies
            .filter { ruby in
                ruby.start >= 0
                    && ruby.length > 0
                    && ruby.start + ruby.length <= textCount
            }
            .sorted { first, second in
                first.start < second.start
            }
        var cursor = 0
        var segments: [ForumThreadRubySegment] = []

        for ruby in sortedRubies {
            guard ruby.start >= cursor else { continue }
            if cursor < ruby.start,
               let slice = slice(of: attributed, start: cursor, length: ruby.start - cursor) {
                segments.append(ForumThreadRubySegment(attributedText: slice, rubyText: nil))
            }
            if let slice = slice(of: attributed, start: ruby.start, length: ruby.length) {
                segments.append(ForumThreadRubySegment(attributedText: slice, rubyText: ruby.rubyText))
            }
            cursor = ruby.start + ruby.length
        }

        if cursor < textCount,
           let slice = slice(of: attributed, start: cursor, length: textCount - cursor) {
            segments.append(ForumThreadRubySegment(attributedText: slice, rubyText: nil))
        }

        return segments
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

    private func slice(of attributed: AttributedString, start: Int, length: Int) -> AttributedString? {
        guard length > 0 else { return nil }
        let startIndex = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let endIndex = attributed.index(startIndex, offsetByCharacters: length)
        return AttributedString(attributed[startIndex ..< endIndex])
    }

    private func font(for style: ForumThreadTextStyle) -> Font {
        // Styled runs must track Dynamic Type like the unstyled body text
        // around them, so the author-relative size is scaled through the
        // body text style's metrics instead of being frozen at 17pt.
        let baseSize = 17 * (style.relativeFontSize ?? 1)
        let scaledSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: baseSize)
        var font = Font.system(size: scaledSize)
        if style.isBold {
            font = font.bold()
        }
        if style.isItalic {
            font = font.italic()
        }
        return font
    }
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
    private var cachedAttributedText: AttributedString?
    private var cachedRubySegments: [ForumThreadRubySegment]?

    func attributedText(for block: ForumThreadTextBlock) -> AttributedString {
        if cachedBlock == block, let cachedAttributedText {
            return cachedAttributedText
        }
        let attributedText = ForumThreadTextBlockFormatter(block: block).attributedText
        updateCache(for: block, attributedText: attributedText, rubySegments: nil)
        return attributedText
    }

    func rubySegments(for block: ForumThreadTextBlock) -> [ForumThreadRubySegment] {
        if cachedBlock == block, let cachedRubySegments {
            return cachedRubySegments
        }
        let rubySegments = ForumThreadTextBlockFormatter(block: block).rubySegments
        updateCache(for: block, attributedText: nil, rubySegments: rubySegments)
        return rubySegments
    }

    private func updateCache(
        for block: ForumThreadTextBlock,
        attributedText: AttributedString?,
        rubySegments: [ForumThreadRubySegment]?
    ) {
        if cachedBlock != block {
            cachedAttributedText = nil
            cachedRubySegments = nil
        }
        cachedBlock = block
        if let attributedText {
            cachedAttributedText = attributedText
        }
        if let rubySegments {
            cachedRubySegments = rubySegments
        }
    }
}

private extension Color {
    init?(forumThreadHex hex: String?) {
        guard let hex else { return nil }
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6,
              let value = UInt64(normalized, radix: 16) else {
            return nil
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

import Foundation
import UIKit
import YamiboXCore

typealias ReaderPlatformColor = UIColor
typealias ReaderPlatformFont = UIFont
typealias ReaderPlatformFontDescriptor = UIFontDescriptor
typealias ReaderPlatformFontWeight = UIFont.Weight

extension NSAttributedString.Key {
    static let novelRuby = NSAttributedString.Key("yamibo.novel.ruby")
    static let novelAuthoredBackground = NSAttributedString.Key("yamibo.novel.authoredBackground")
}

final class NovelRubyAnnotation: NSObject {
    let text: String

    init(text: String) { self.text = text }
}

/// Owns the Novel Text Attributed Document semantics for TextKit measurement
/// and drawing: chapter title styling, paragraph indentation, font family,
/// kerning, line height, and justification.
enum NovelAttributedTextFactory {
    static let defaultBaseFontSize: Double = 22
    /// Leading tracks the type size (6pt of extra leading at the default
    /// 22pt body) instead of staying a fixed 6pt: a fixed value reads loose
    /// at small sizes and cramped at large ones. `lineHeightScale` still
    /// multiplies on top as the user's own adjustment.
    static let lineSpacingRatio: Double = 6.0 / 22.0
    private static let bodyFontWeight: ReaderPlatformFontWeight = .light

    static func makeAttributedDocument(
        from preparedInput: NovelTextLayoutPreparedInput
    ) -> NSAttributedString {
        let document = NSMutableAttributedString()
        var hasText = false

        for annotatedSegment in preparedInput.annotatedSegments {
            guard case let .text(text, _) = annotatedSegment.segment else {
                continue
            }
            if hasText {
                document.append(
                    makeAttributedText(
                        text: "\n\n",
                        chapterTitleRange: nil,
                        settings: preparedInput.settings
                    )
                )
            }
            document.append(
                makeAttributedText(
                    text: text,
                    chapterTitleRange: annotatedSegment.semantics?.chapterTitleRange,
                    inlineTextStyles: annotatedSegment.semantics?.inlineTextStyles ?? [],
                    blockTextStyles: annotatedSegment.semantics?.blockTextStyles ?? [],
                    settings: preparedInput.settings
                )
            )
            hasText = true
        }

        return document
    }

    static func resolvedFontFingerprint(
        settings: NovelReaderAppearanceSettings,
        baseFontSize: Double = defaultBaseFontSize
    ) -> String {
        let font = settings.readerFont(
            size: baseFontSize * settings.fontScale,
            weight: bodyFontWeight
        )
        return [
            settings.fontSelection.stableID,
            settings.resolvedFont?.fingerprint ?? "unresolved",
            font.fontName,
            font.familyName,
            String(describing: font.pointSize),
            settings.readerFont(size: font.pointSize, weight: .bold).fontName,
        ].joined(separator: "|")
    }

    static func makeAttributedText(
        text: String,
        chapterTitle: String?,
        startsAtParagraphBoundary: Bool = true,
        settings: NovelReaderAppearanceSettings,
        baseFontSize: Double = defaultBaseFontSize,
        textColor: ReaderPlatformColor? = nil,
        titleWeight: ReaderPlatformFontWeight = .bold
    ) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        let segments = NovelChapterTextComponents.split(text: text, chapterTitle: chapterTitle)
        let attributes = makeTextAttributes(
            settings: settings, baseFontSize: baseFontSize, textColor: textColor,
            titleWeight: titleWeight, startsAtParagraphBoundary: startsAtParagraphBoundary
        )

        if let title = segments.title {
            rendered.append(NSAttributedString(string: title, attributes: attributes.title))
            if let body = segments.body {
                appendBody(
                    body,
                    to: rendered,
                    attributes: attributes.body,
                    laterParagraphStyle: attributes.laterBodyParagraphStyle,
                    startsAtParagraphBoundary: startsAtParagraphBoundary
                )
            }
        } else {
            appendBody(
                text,
                to: rendered,
                attributes: attributes.body,
                laterParagraphStyle: attributes.laterBodyParagraphStyle,
                startsAtParagraphBoundary: startsAtParagraphBoundary
            )
        }

        return rendered
    }

    static func makeAttributedText(
        text: String,
        chapterTitleRange: NSRange?,
        inlineTextStyles: [NovelRuntimeInlineTextStyle] = [],
        blockTextStyles: [NovelRuntimeBlockTextStyle] = [],
        startsAtParagraphBoundary: Bool = true,
        settings: NovelReaderAppearanceSettings,
        baseFontSize: Double = defaultBaseFontSize,
        textColor: ReaderPlatformColor? = nil,
        titleWeight: ReaderPlatformFontWeight = .bold
    ) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        let attributes = makeTextAttributes(
            settings: settings, baseFontSize: baseFontSize, textColor: textColor,
            titleWeight: titleWeight, startsAtParagraphBoundary: startsAtParagraphBoundary
        )

        rendered.append(NSAttributedString(string: text, attributes: attributes.body))

        if !startsAtParagraphBoundary {
            for range in NovelParagraphIndentPlanner.indentedParagraphRangesAfterFirst(in: text) {
                let utf16Range = NSRange(range, in: text)
                guard utf16Range.length > 0 else { continue }
                rendered.addAttribute(
                    .paragraphStyle,
                    value: attributes.laterBodyParagraphStyle,
                    range: utf16Range
                )
            }
        }

        if let titleRange = titleRange(from: chapterTitleRange, in: text) {
            rendered.addAttributes(attributes.title, range: titleRange)
        }
        applyInlineTextStyles(
            inlineTextStyles,
            blockTextStyles: blockTextStyles,
            chapterTitleRange: titleRange(from: chapterTitleRange, in: text),
            to: rendered,
            text: text,
            settings: settings,
            pointSize: attributes.pointSize
        )

        return rendered
    }

    private struct TextAttributes {
        let pointSize: Double
        let body: [NSAttributedString.Key: Any]
        let title: [NSAttributedString.Key: Any]
        let laterBodyParagraphStyle: NSParagraphStyle
    }

    private static func makeTextAttributes(
        settings: NovelReaderAppearanceSettings,
        baseFontSize: Double,
        textColor: ReaderPlatformColor?,
        titleWeight: ReaderPlatformFontWeight,
        startsAtParagraphBoundary: Bool
    ) -> TextAttributes {
        let textColor = textColor ?? readerThemeTextUIColor(for: settings.backgroundStyle)
        let pointSize = baseFontSize * settings.fontScale
        let firstBodyParagraphStyle = makeParagraphStyle(
            settings: settings, pointSize: pointSize, appliesFirstLineIndent: startsAtParagraphBoundary
        )
        let laterBodyParagraphStyle = makeParagraphStyle(
            settings: settings, pointSize: pointSize, appliesFirstLineIndent: true
        )
        let titleParagraphStyle = makeParagraphStyle(settings: settings, pointSize: pointSize, appliesFirstLineIndent: false)
        return TextAttributes(
            pointSize: pointSize,
            body: [
                .font: settings.readerFont(size: pointSize, weight: bodyFontWeight),
                .kern: CGFloat(pointSize * settings.characterSpacingScale * 0.55),
                .foregroundColor: textColor,
                .paragraphStyle: firstBodyParagraphStyle,
            ],
            title: [
                .font: settings.readerFont(size: pointSize, weight: titleWeight),
                .kern: CGFloat(pointSize * settings.characterSpacingScale * 0.55),
                .foregroundColor: textColor,
                .paragraphStyle: titleParagraphStyle,
            ],
            laterBodyParagraphStyle: laterBodyParagraphStyle
        )
    }

    static func makeParagraphStyle(settings: NovelReaderAppearanceSettings) -> NSMutableParagraphStyle {
        makeParagraphStyle(settings: settings, pointSize: defaultBaseFontSize, appliesFirstLineIndent: true)
    }

    private static func makeParagraphStyle(
        settings: NovelReaderAppearanceSettings,
        pointSize: Double,
        appliesFirstLineIndent: Bool
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = pointSize * Self.lineSpacingRatio * settings.lineHeightScale
        style.alignment = settings.usesJustifiedText ? .justified : .natural
        style.lineBreakMode = .byWordWrapping
        if settings.indentsParagraphFirstLine, appliesFirstLineIndent {
            style.firstLineHeadIndent = CGFloat(pointSize * 2)
        }
        return style
    }

    private static func appendBody(
        _ body: String,
        to rendered: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any],
        laterParagraphStyle: NSParagraphStyle,
        startsAtParagraphBoundary: Bool
    ) {
        let bodyStartLocation = rendered.length
        rendered.append(NSAttributedString(string: body, attributes: attributes))
        guard !startsAtParagraphBoundary else { return }

        for range in NovelParagraphIndentPlanner.indentedParagraphRangesAfterFirst(in: body) {
            let utf16Range = NSRange(range, in: body)
            guard utf16Range.length > 0 else { continue }
            rendered.addAttribute(
                .paragraphStyle,
                value: laterParagraphStyle,
                range: NSRange(location: bodyStartLocation + utf16Range.location, length: utf16Range.length)
            )
        }
    }

    private static func titleRange(
        from chapterTitleRange: NSRange?,
        in text: String
    ) -> NSRange? {
        guard let chapterTitleRange,
              chapterTitleRange.length > 0,
              chapterTitleRange.location >= 0,
              chapterTitleRange.location <= (text as NSString).length,
              chapterTitleRange.length <= (text as NSString).length - chapterTitleRange.location else {
            return nil
        }
        return NSRange(location: chapterTitleRange.location, length: chapterTitleRange.length)
    }

    private static func applyInlineTextStyles(
        _ inlineTextStyles: [NovelRuntimeInlineTextStyle],
        blockTextStyles: [NovelRuntimeBlockTextStyle],
        chapterTitleRange: NSRange?,
        to rendered: NSMutableAttributedString,
        text: String,
        settings: NovelReaderAppearanceSettings,
        pointSize: Double
    ) {
        let enabled = settings.forumFormat
        let valid = inlineTextStyles.compactMap { style -> (NovelRuntimeInlineTextStyle, NSRange)? in
            textRange(from: style.range, in: text).map { (style, $0) }
        }
        let title = rendered.length > 0 ? rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
        let fontStyles = valid.filter {
            ($0.0.style == .bold && enabled.bold) || ($0.0.style == .italic && enabled.italic)
        }
        if !fontStyles.isEmpty {
            let titleEdges = chapterTitleRange.map { [$0.location, NSMaxRange($0)] } ?? []
            let boundaries = Set([0, rendered.length] + titleEdges
                                 + fontStyles.flatMap { [$0.1.location, NSMaxRange($0.1)] }).sorted()
            for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                let isBold = fontStyles.contains { $0.0.style == .bold && NSLocationInRange(start, $0.1) }
                let isItalic = fontStyles.contains { $0.0.style == .italic && NSLocationInRange(start, $0.1) }
                guard isBold || isItalic else { continue }
                let current = rendered.attribute(.font, at: start, effectiveRange: nil) as? UIFont ?? title
                let titleIsBold = chapterTitleRange.map { NSLocationInRange(start, $0) } == true
                    || current?.fontDescriptor.symbolicTraits.contains(.traitBold) == true
                let base = settings.readerFont(size: pointSize, weight: isBold || titleIsBold ? .bold : .light)
                rendered.addAttribute(.font, value: isItalic ? italicFont(base) : base,
                                      range: NSRange(location: start, length: end - start))
            }
        }

        for (style, range) in valid {
            switch style.style {
            case .underline where enabled.underline:
                rendered.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .strikethrough where enabled.strikethrough:
                rendered.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .ruby where enabled.ruby:
                if let annotation = style.rubyText, !annotation.isEmpty {
                    rendered.addAttribute(.novelRuby, value: NovelRubyAnnotation(text: annotation), range: range)
                }
            default:
                break
            }
        }

        let colors = valid.filter {
            ($0.0.style == .foregroundColor && enabled.textColor && $0.0.colorHex != nil) ||
            ($0.0.style == .backgroundColor && enabled.backgroundColor && $0.0.colorHex != nil)
        }
        if !colors.isEmpty {
            let quoteRanges = enabled.quote ? blockTextStyles.compactMap { textRange(from: $0.range, in: text) } : []
            let boundaries = Set([0, rendered.length] + colors.flatMap { [$0.1.location, NSMaxRange($0.1)] }
                                 + quoteRanges.flatMap { [$0.location, NSMaxRange($0)] }).sorted()
            for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                let foreground = colors.last { $0.0.style == .foregroundColor && NSLocationInRange(start, $0.1) }?.0.colorHex
                let background = colors.last { $0.0.style == .backgroundColor && NSLocationInRange(start, $0.1) }?.0.colorHex
                guard foreground != nil || background != nil else { continue }
                let isQuote = quoteRanges.contains { NSLocationInRange(start, $0) }
                if let background, let color = NovelForumColorRenderer.color(hex: background) {
                    rendered.addAttribute(.novelAuthoredBackground, value: color,
                                          range: NSRange(location: start, length: end - start))
                }
                rendered.addAttribute(.foregroundColor,
                    value: NovelForumColorRenderer.foreground(authoredHex: foreground, backgroundHex: background,
                                                               isQuote: isQuote, settings: settings),
                    range: NSRange(location: start, length: end - start))
            }
        }

        if enabled.ruby, rendered.length > 0 {
            let extra = ceil(pointSize * 0.5) + 2
            var paragraphRanges: [NSRange] = []
            rendered.enumerateAttribute(.novelRuby, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
                guard value != nil else { return }
                paragraphRanges.append((text as NSString).paragraphRange(for: range))
            }
            for range in Set(paragraphRanges) where range.length > 0 {
                guard let paragraph = rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                      let adjusted = paragraph.mutableCopy() as? NSMutableParagraphStyle else { continue }
                adjusted.lineSpacing += extra
                adjusted.paragraphSpacingBefore = max(adjusted.paragraphSpacingBefore, extra)
                rendered.addAttribute(.paragraphStyle, value: adjusted, range: range)
            }
        }
    }

    private static func italicFont(_ font: UIFont) -> UIFont {
        if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            let candidate = UIFont(descriptor: descriptor, size: font.pointSize)
            if candidate.familyName == font.familyName,
               candidate.fontDescriptor.symbolicTraits.contains(.traitItalic) {
                return candidate
            }
        }
        return UIFont(descriptor: font.fontDescriptor.withMatrix(
            CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        ), size: font.pointSize)
    }

    private static func textRange(
        from range: NSRange,
        in text: String
    ) -> NSRange? {
        guard range.length > 0,
              range.location >= 0,
              range.location <= (text as NSString).length,
              range.length <= (text as NSString).length - range.location else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }
}

extension NovelReaderAppearanceSettings {
    func readerFont(size: Double, weight: UIFont.Weight) -> UIFont {
        if let resolvedFont {
            let name = weight == .bold ? resolvedFont.boldName : resolvedFont.bodyName
            if let font = UIFont(name: name, size: size) { return font }
        }
        // Standalone layout callers may not have prepared the library. Never
        // pretend a serif or rounded system design is a Chinese font family.
        if case let .curated(curated) = fontSelection {
            let fonts = UIFont.fontNames(forFamilyName: curated.familyName).compactMap { UIFont(name: $0, size: size) }
            let suffix = weight == .bold ? "-Bold" : "-Light"
            if let font = fonts.first(where: { $0.fontName.hasSuffix(suffix) })
                ?? fonts.first(where: { $0.fontName.hasSuffix("-Regular") }) { return font }
        }
        return UIFont(name: weight == .bold ? "PingFangSC-Semibold" : "PingFangSC-Light", size: size)
            ?? .systemFont(ofSize: size, weight: weight)
    }
}

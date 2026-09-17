import Foundation
import UIKit
import YamiboXCore

typealias ReaderPlatformColor = UIColor
typealias ReaderPlatformFont = UIFont
typealias ReaderPlatformFontDescriptor = UIFontDescriptor
typealias ReaderPlatformFontWeight = UIFont.Weight

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
        let font = settings.fontFamily.platformFont(
            size: baseFontSize * settings.fontScale,
            weight: bodyFontWeight
        )
        return [
            font.fontName,
            font.familyName,
            String(describing: font.pointSize),
            String(describing: font.fontDescriptor.fontAttributes),
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
        let textColor = textColor ?? readerThemeTextUIColor(for: settings.backgroundStyle)
        let segments = NovelChapterTextComponents.split(text: text, chapterTitle: chapterTitle)
        let pointSize = baseFontSize * settings.fontScale
        let firstBodyParagraphStyle = makeParagraphStyle(
            settings: settings,
            pointSize: pointSize,
            appliesFirstLineIndent: startsAtParagraphBoundary
        )
        let laterBodyParagraphStyle = makeParagraphStyle(
            settings: settings,
            pointSize: pointSize,
            appliesFirstLineIndent: true
        )
        let titleParagraphStyle = makeParagraphStyle(settings: settings, pointSize: pointSize, appliesFirstLineIndent: false)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: settings.fontFamily.platformFont(size: pointSize, weight: bodyFontWeight),
            .kern: settings.fontFamily.kerning(size: pointSize, scale: settings.characterSpacingScale),
            .foregroundColor: textColor,
            .paragraphStyle: firstBodyParagraphStyle,
        ]
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: settings.fontFamily.platformFont(size: pointSize, weight: titleWeight),
            .kern: settings.fontFamily.kerning(size: pointSize, scale: settings.characterSpacingScale),
            .foregroundColor: textColor,
            .paragraphStyle: titleParagraphStyle,
        ]

        if let title = segments.title {
            rendered.append(NSAttributedString(string: title, attributes: titleAttributes))
            if let body = segments.body {
                appendBody(
                    body,
                    to: rendered,
                    attributes: bodyAttributes,
                    laterParagraphStyle: laterBodyParagraphStyle,
                    startsAtParagraphBoundary: startsAtParagraphBoundary
                )
            }
        } else {
            appendBody(
                text,
                to: rendered,
                attributes: bodyAttributes,
                laterParagraphStyle: laterBodyParagraphStyle,
                startsAtParagraphBoundary: startsAtParagraphBoundary
            )
        }

        return rendered
    }

    static func makeAttributedText(
        text: String,
        chapterTitleRange: NSRange?,
        inlineTextStyles: [NovelRuntimeInlineTextStyle] = [],
        startsAtParagraphBoundary: Bool = true,
        settings: NovelReaderAppearanceSettings,
        baseFontSize: Double = defaultBaseFontSize,
        textColor: ReaderPlatformColor? = nil,
        titleWeight: ReaderPlatformFontWeight = .bold
    ) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        let textColor = textColor ?? readerThemeTextUIColor(for: settings.backgroundStyle)
        let pointSize = baseFontSize * settings.fontScale
        let firstBodyParagraphStyle = makeParagraphStyle(
            settings: settings,
            pointSize: pointSize,
            appliesFirstLineIndent: startsAtParagraphBoundary
        )
        let laterBodyParagraphStyle = makeParagraphStyle(
            settings: settings,
            pointSize: pointSize,
            appliesFirstLineIndent: true
        )
        let titleParagraphStyle = makeParagraphStyle(settings: settings, pointSize: pointSize, appliesFirstLineIndent: false)
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: settings.fontFamily.platformFont(size: pointSize, weight: bodyFontWeight),
            .kern: settings.fontFamily.kerning(size: pointSize, scale: settings.characterSpacingScale),
            .foregroundColor: textColor,
            .paragraphStyle: firstBodyParagraphStyle,
        ]
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: settings.fontFamily.platformFont(size: pointSize, weight: titleWeight),
            .kern: settings.fontFamily.kerning(size: pointSize, scale: settings.characterSpacingScale),
            .foregroundColor: textColor,
            .paragraphStyle: titleParagraphStyle,
        ]

        rendered.append(NSAttributedString(string: text, attributes: bodyAttributes))

        if !startsAtParagraphBoundary {
            for range in NovelParagraphIndentPlanner.indentedParagraphRangesAfterFirst(in: text) {
                let utf16Range = NSRange(range, in: text)
                guard utf16Range.length > 0 else { continue }
                rendered.addAttribute(
                    .paragraphStyle,
                    value: laterBodyParagraphStyle,
                    range: utf16Range
                )
            }
        }

        if let titleRange = titleRange(from: chapterTitleRange, in: text) {
            rendered.addAttributes(titleAttributes, range: titleRange)
        }
        applyInlineTextStyles(
            inlineTextStyles,
            to: rendered,
            text: text,
            settings: settings,
            pointSize: pointSize
        )

        return rendered
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
        to rendered: NSMutableAttributedString,
        text: String,
        settings: NovelReaderAppearanceSettings,
        pointSize: Double
    ) {
        for inlineStyle in inlineTextStyles {
            guard inlineStyle.style == .bold,
                  let range = textRange(from: inlineStyle.range, in: text) else {
                continue
            }
            rendered.addAttribute(
                .font,
                value: settings.fontFamily.platformFont(size: pointSize, weight: .bold),
                range: range
            )
        }
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

extension ReaderFontFamily {
    func platformFont(size: Double, weight: ReaderPlatformFontWeight) -> ReaderPlatformFont {
        let pointSize = CGFloat(size)
        switch self {
        case .systemSans:
            return preferredFamilyFont(familyName: "PingFang SC", size: pointSize, weight: weight)
                ?? .systemFont(ofSize: pointSize, weight: weight)
        case .systemSerif:
            return preferredFamilyFont(familyName: "Songti SC", size: pointSize, weight: weight)
                ?? systemFont(size: pointSize, weight: weight, design: .serif)
                ?? .systemFont(ofSize: pointSize, weight: weight)
        case .rounded:
            return systemFont(size: pointSize, weight: weight, design: .rounded)
                ?? .systemFont(ofSize: pointSize, weight: weight)
        }
    }

    func uiFont(size: Double, weight: UIFont.Weight) -> UIFont {
        platformFont(size: size, weight: weight)
    }

    func kerning(size: Double, scale: Double) -> CGFloat {
        CGFloat(size * scale * 0.55)
    }

    private func preferredFamilyFont(
        familyName: String,
        size: CGFloat,
        weight: ReaderPlatformFontWeight
    ) -> ReaderPlatformFont? {
        let descriptor = ReaderPlatformFontDescriptor(
            fontAttributes: [
                .family: familyName,
                .traits: [ReaderPlatformFontDescriptor.TraitKey.weight: weight],
            ]
        )
        let font = ReaderPlatformFont(descriptor: descriptor, size: size)
        return font.familyName == familyName ? font : nil
    }

    private func systemFont(
        size: CGFloat,
        weight: ReaderPlatformFontWeight,
        design: ReaderPlatformFontDescriptor.SystemDesign
    ) -> ReaderPlatformFont? {
        let baseDescriptor = ReaderPlatformFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        guard let designedDescriptor = baseDescriptor.withDesign(design) else {
            return nil
        }

        return ReaderPlatformFont(descriptor: designedDescriptor, size: size)
    }
}

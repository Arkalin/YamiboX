import Foundation
import UIKit
import YamiboXCore

typealias ReaderPlatformColor = UIColor
typealias ReaderPlatformFont = UIFont
typealias ReaderPlatformFontDescriptor = UIFontDescriptor
typealias ReaderPlatformFontWeight = UIFont.Weight

private extension ReaderPlatformColor {
    static func readerText(settings: NovelReaderAppearanceSettings) -> ReaderPlatformColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(white: 1, alpha: 0.86)
            }

            return lightReaderText(backgroundStyle: settings.backgroundStyle)
        }
    }

    private static func lightReaderText(backgroundStyle: ReaderBackgroundStyle) -> ReaderPlatformColor {
        switch backgroundStyle {
        case .system, .paper:
            return UIColor(red: 0.23, green: 0.19, blue: 0.15, alpha: 1)
        case .mint:
            return UIColor(red: 0.15, green: 0.21, blue: 0.18, alpha: 1)
        case .sakura:
            return UIColor(red: 0.23, green: 0.17, blue: 0.19, alpha: 1)
        }
    }
}

/// Owns the Novel Text Attributed Document semantics for TextKit measurement
/// and drawing: chapter title styling, paragraph indentation, font family,
/// kerning, line height, and justification.
enum NovelAttributedTextFactory {
    static let defaultBaseFontSize: Double = 22
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
        let textColor = textColor ?? .readerText(settings: settings)
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
        chapterTitleRange: NovelCharacterRange?,
        inlineTextStyles: [NovelInlineTextStyleRange] = [],
        startsAtParagraphBoundary: Bool = true,
        settings: NovelReaderAppearanceSettings,
        baseFontSize: Double = defaultBaseFontSize,
        textColor: ReaderPlatformColor? = nil,
        titleWeight: ReaderPlatformFontWeight = .bold
    ) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        let textColor = textColor ?? .readerText(settings: settings)
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
                let location = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                guard length > 0 else { continue }
                rendered.addAttribute(
                    .paragraphStyle,
                    value: laterBodyParagraphStyle,
                    range: NSRange(location: location, length: length)
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
        style.lineSpacing = 6 * settings.lineHeightScale
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
            let location = body.distance(from: body.startIndex, to: range.lowerBound)
            let length = body.distance(from: range.lowerBound, to: range.upperBound)
            guard length > 0 else { continue }
            rendered.addAttribute(
                .paragraphStyle,
                value: laterParagraphStyle,
                range: NSRange(location: bodyStartLocation + location, length: length)
            )
        }
    }

    private static func titleRange(
        from chapterTitleRange: NovelCharacterRange?,
        in text: String
    ) -> NSRange? {
        guard let chapterTitleRange,
              chapterTitleRange.length > 0,
              chapterTitleRange.location >= 0,
              chapterTitleRange.upperBound <= text.count else {
            return nil
        }
        return NSRange(location: chapterTitleRange.location, length: chapterTitleRange.length)
    }

    private static func applyInlineTextStyles(
        _ inlineTextStyles: [NovelInlineTextStyleRange],
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
        from range: NovelCharacterRange,
        in text: String
    ) -> NSRange? {
        guard range.length > 0,
              range.location >= 0,
              range.upperBound <= text.count else {
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

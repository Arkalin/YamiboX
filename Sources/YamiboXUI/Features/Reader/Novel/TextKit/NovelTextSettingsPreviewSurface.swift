import CoreGraphics
import Foundation
import UIKit
import YamiboXCore

/// Short-lived preview surface for the reader settings sheet. Reuses the
/// attributed-document styling but never builds a viewport index or touches
/// the active reading workflow.
final class NovelTextSettingsPreviewSurface {
    private let attributedText: NSAttributedString

    init(
        text: String,
        settings: NovelReaderAppearanceSettings,
        baseFontSize: Double = NovelAttributedTextFactory.defaultBaseFontSize,
        textColor: ReaderPlatformColor? = nil
    ) {
        attributedText = NovelAttributedTextFactory.makeAttributedText(
            text: text,
            chapterTitle: nil,
            startsAtParagraphBoundary: true,
            settings: settings,
            baseFontSize: baseFontSize,
            textColor: textColor
        )
    }

    func diagnosticParagraphStyle(at location: Int) -> NSParagraphStyle? {
        guard location >= 0, location < attributedText.length else { return nil }
        return attributedText.attribute(
            .paragraphStyle,
            at: location,
            effectiveRange: nil
        ) as? NSParagraphStyle
    }

    func draw(in context: CGContext, bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0, attributedText.length > 0 else {
            return
        }

        context.saveGState()
        context.clip(to: bounds)
        attributedText.draw(
            with: bounds,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        context.restoreGState()
    }
}

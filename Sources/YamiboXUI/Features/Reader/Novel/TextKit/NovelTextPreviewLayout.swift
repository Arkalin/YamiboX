import CoreGraphics
import Foundation
import UIKit
import YamiboXCore

enum NovelTextPreviewLayout {
    static func textFits(
        _ text: String,
        chapterTitle: String?,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout
    ) -> Bool {
        let pageSize = layout.readableFrame.size
        guard pageSize.width >= 120,
              pageSize.height >= minimumUsablePageHeight(settings: settings) else {
            return false
        }
        let height = measuredTextHeight(
            text,
            chapterTitle: chapterTitle,
            startsAtParagraphBoundary: true,
            settings: settings,
            width: pageSize.width,
            baseFontSize: NovelAttributedTextFactory.defaultBaseFontSize
        )
        return height > 0 && height <= pageSize.height
    }

    static func measuredTextHeight(
        _ text: String,
        chapterTitle: String?,
        startsAtParagraphBoundary: Bool,
        settings: NovelReaderAppearanceSettings,
        width: CGFloat,
        baseFontSize: Double
    ) -> CGFloat {
        let attributedText = NovelAttributedTextFactory.makeAttributedText(
            text: text,
            chapterTitle: chapterTitle,
            startsAtParagraphBoundary: startsAtParagraphBoundary,
            settings: settings,
            baseFontSize: baseFontSize
        )
        guard width > 0, attributedText.length > 0 else { return 0 }

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.textStorage?.setAttributedString(attributedText)

        let textContainer = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.textContainer = textContainer
        layoutManager.ensureLayout(for: contentStorage.documentRange)

        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location,
            options: []
        ) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return ceil(maxY)
    }

    private static func minimumUsablePageHeight(
        settings: NovelReaderAppearanceSettings
    ) -> CGFloat {
        let fontSize = max(
            14,
            NovelAttributedTextFactory.defaultBaseFontSize * settings.fontScale
        )
        return CGFloat(fontSize * max(settings.lineHeightScale, 1.35) * 2)
    }
}

extension NovelTextLayout {
    /// Standalone one-shot layout through the production TextKit adapter.
    /// Test-facing convenience; production reading always goes through
    /// `NovelReadingWorkflow`'s runtime transactions.
    package static func layout(
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout
    ) throws -> NovelTextLayoutResult {
        let operation: () throws -> NovelTextLayoutResult = {
            let runtime = NovelTextViewportRuntimeOwner(
                adapter: DefaultNovelTextLayoutRuntimeAdapter()
            )
            let transaction = try runtime.prepareTransaction(
                preparedInput: try NovelTextLayout.prepareInput(
                    document: document,
                    settings: settings,
                    layout: layout
                )
            )
            return transaction.result
        }
        if Thread.isMainThread {
            return try operation()
        }
        return try DispatchQueue.main.sync(execute: operation)
    }
}

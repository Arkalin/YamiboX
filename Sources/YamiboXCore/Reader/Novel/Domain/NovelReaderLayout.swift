import CoreGraphics
import Foundation

public struct NovelReaderLayout: Hashable, Sendable {
    public var containerSize: CGSize
    public var safeAreaInsets: NovelReaderLayoutInsets
    public var contentInsets: NovelReaderLayoutInsets
    public var chromeInsets: NovelReaderLayoutInsets
    public var readingMode: ReaderReadingMode

    public init(
        width: CGFloat,
        height: CGFloat,
        safeAreaInsets: NovelReaderLayoutInsets = .zero,
        contentInsets: NovelReaderLayoutInsets = .zero,
        chromeInsets: NovelReaderLayoutInsets = .zero,
        readingMode: ReaderReadingMode = .paged
    ) {
        self.init(
            containerSize: CGSize(width: width, height: height),
            safeAreaInsets: safeAreaInsets,
            contentInsets: contentInsets,
            chromeInsets: chromeInsets,
            readingMode: readingMode
        )
    }

    public init(
        containerSize: CGSize,
        safeAreaInsets: NovelReaderLayoutInsets = .zero,
        contentInsets: NovelReaderLayoutInsets = .zero,
        chromeInsets: NovelReaderLayoutInsets = .zero,
        readingMode: ReaderReadingMode = .paged
    ) {
        self.containerSize = containerSize
        self.safeAreaInsets = safeAreaInsets
        self.contentInsets = contentInsets
        self.chromeInsets = chromeInsets
        self.readingMode = readingMode
    }

    public var width: CGFloat { containerSize.width }
    public var height: CGFloat { containerSize.height }

    public var readableFrame: CGRect {
        let totalInsets = safeAreaInsets + contentInsets + chromeInsets
        let width = max(0, containerSize.width - totalInsets.leading - totalInsets.trailing)
        let height = max(0, containerSize.height - totalInsets.top - totalInsets.bottom)
        return CGRect(
            x: totalInsets.leading,
            y: totalInsets.top,
            width: width,
            height: height
        )
    }

    public static let zero = NovelReaderLayout(containerSize: .zero)

    public func novelTextBoxLayout(
        settings: NovelReaderAppearanceSettings,
        usesPadPresentation: Bool
    ) -> NovelReaderLayout {
        guard settings.readingMode == .paged,
              settings.showsTwoPagesInLandscapeOnPad,
              usesPadPresentation,
              width > height else {
            return self
        }

        return NovelReaderLayout(
            containerSize: CGSize(width: width / 2, height: height),
            safeAreaInsets: NovelReaderLayoutInsets(
                top: safeAreaInsets.top,
                bottom: safeAreaInsets.bottom
            ),
            contentInsets: contentInsets,
            chromeInsets: chromeInsets,
            readingMode: readingMode
        )
    }
}

public struct NovelReaderLayoutInsets: Hashable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(
        top: CGFloat = 0,
        leading: CGFloat = 0,
        bottom: CGFloat = 0,
        trailing: CGFloat = 0
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = NovelReaderLayoutInsets()
}

public func + (lhs: NovelReaderLayoutInsets, rhs: NovelReaderLayoutInsets) -> NovelReaderLayoutInsets {
    NovelReaderLayoutInsets(
        top: lhs.top + rhs.top,
        leading: lhs.leading + rhs.leading,
        bottom: lhs.bottom + rhs.bottom,
        trailing: lhs.trailing + rhs.trailing
    )
}

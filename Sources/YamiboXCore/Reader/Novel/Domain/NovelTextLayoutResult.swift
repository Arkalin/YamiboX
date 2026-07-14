import CoreGraphics
import Foundation

package struct NovelTextViewportSurfaceLayoutMetrics: Hashable, Sendable {
    public var surfaceOrdinal: Int
    public var textHeight: CGFloat?
    public var externalBlockHeight: CGFloat
    public var spacingHeight: CGFloat

    public init(
        surfaceOrdinal: Int,
        textHeight: CGFloat? = nil,
        externalBlockHeight: CGFloat = 0,
        spacingHeight: CGFloat = 0
    ) {
        self.surfaceOrdinal = max(0, surfaceOrdinal)
        self.textHeight = textHeight
        self.externalBlockHeight = max(0, externalBlockHeight)
        self.spacingHeight = max(0, spacingHeight)
    }

    public var contentHeight: CGFloat {
        max(0, textHeight ?? 0) + externalBlockHeight + spacingHeight
    }
}

package struct NovelTextViewportLayoutMetrics: Hashable, Sendable {
    public var surfaceMetrics: [Int: NovelTextViewportSurfaceLayoutMetrics]

    public init(surfaceMetrics: [Int: NovelTextViewportSurfaceLayoutMetrics] = [:]) {
        self.surfaceMetrics = surfaceMetrics
    }

    public func surfaceHeight(for surfaceOrdinal: Int) -> CGFloat? {
        surfaceMetrics[max(0, surfaceOrdinal)]?.contentHeight
    }
}

package struct NovelTextLayoutResult: Hashable, Sendable {
    public var viewportContext: NovelTextViewportContext
    public var viewportIndex: NovelTextViewportIndex
    public var layoutMetrics: NovelTextViewportLayoutMetrics
    public var fingerprints: NovelTextLayoutFingerprints

    public init(
        viewportContext: NovelTextViewportContext,
        viewportIndex: NovelTextViewportIndex,
        layoutMetrics: NovelTextViewportLayoutMetrics = NovelTextViewportLayoutMetrics(),
        fingerprints: NovelTextLayoutFingerprints = NovelTextLayoutFingerprints()
    ) {
        self.viewportContext = viewportContext
        self.viewportIndex = viewportIndex
        self.layoutMetrics = layoutMetrics
        self.fingerprints = fingerprints
    }
}

package struct NovelTextLayoutFingerprints: Hashable, Sendable {
    public var semantic: String
    public var text: String
    public var layout: String
    public var font: String
    public var platform: String
    public var textKitImplementation: String

    public init(
        semantic: String = "",
        text: String = "",
        layout: String = "",
        font: String = "",
        platform: String = "",
        textKitImplementation: String = ""
    ) {
        self.semantic = semantic
        self.text = text
        self.layout = layout
        self.font = font
        self.platform = platform
        self.textKitImplementation = textKitImplementation
    }
}

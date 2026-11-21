import CoreGraphics
import Foundation
import YamiboXCore

public final class NovelTextViewportDisplayReference {
    public let surfaceIdentity: NovelReaderSurfaceIdentity
    var surfaceOrdinal: Int { surfaceIdentity.ordinal }
    public var generation: UInt64 { surfaceIdentity.generation }

    var runtimeIdentity: UUID? { runtimeOwner?.identity }

    var surfaceDocumentRange: Range<NovelDocumentUTF16Offset>? {
        runtimeOwner?.surfaceDocumentRange(for: surfaceIdentity)
    }

    private weak var runtimeOwner: NovelTextViewportRuntimeOwner?

    init(
        runtimeOwner: NovelTextViewportRuntimeOwner,
        surfaceIdentity: NovelReaderSurfaceIdentity
    ) {
        self.runtimeOwner = runtimeOwner
        self.surfaceIdentity = surfaceIdentity
    }

    public var isStale: Bool {
        guard let runtimeOwner else { return true }
        return !runtimeOwner.isCurrent(surfaceIdentity)
    }

    func viewportSample(referencePoint: CGPoint) -> NovelTextViewportSample? {
        runtimeOwner?.viewportSample(
            surfaceIdentity: surfaceIdentity,
            referencePoint: referencePoint
        )
    }

    func referenceY(for position: NovelResumePoint) -> CGFloat? {
        runtimeOwner?.referenceY(
            surfaceIdentity: surfaceIdentity,
            position: position
        )
    }

    func selectionAnchor(at referencePoint: CGPoint) -> NovelTextSelectionAnchor? {
        runtimeOwner?.selectionAnchor(
            surfaceIdentity: surfaceIdentity,
            referencePoint: referencePoint
        )
    }

    func expandedSelectionRange(
        around anchor: NovelTextSelectionAnchor
    ) -> NovelTextSelectionRange? {
        runtimeOwner?.expandedSelectionRange(around: anchor)
    }

    func selectionRange(
        from start: NovelTextSelectionAnchor,
        to end: NovelTextSelectionAnchor
    ) -> NovelTextSelectionRange? {
        runtimeOwner?.selectionRange(from: start, to: end)
    }

    func selectionRects(
        for selectionRange: NovelTextSelectionRange
    ) -> [CGRect] {
        runtimeOwner?.selectionRects(
            for: selectionRange,
            surfaceIdentity: surfaceIdentity
        ) ?? []
    }

    func selectedText(
        for selectionRange: NovelTextSelectionRange
    ) -> String? {
        runtimeOwner?.selectedText(for: selectionRange)
    }

    func semanticTextPosition(
        containingDocumentOffset documentOffset: NovelDocumentUTF16Offset
    ) -> NovelTextViewportSemanticTextPosition? {
        runtimeOwner?.semanticTextPosition(containingDocumentOffset: documentOffset)
    }

    func surroundingText(
        for selectionRange: NovelTextSelectionRange,
        radius: Int
    ) -> (before: String, after: String)? {
        runtimeOwner?.surroundingText(for: selectionRange, radius: radius)
    }

    func chapterTitle(for segmentIdentity: NovelTextSegmentIdentity) -> String? {
        guard !isStale else { return nil }
        return runtimeOwner?.chapterTitle(for: segmentIdentity)
    }

    func highlightRange(for anchor: NovelTextLikeAnchor, workKey: ReadingWorkKey) -> NovelTextSelectionRange? {
        guard !isStale else { return nil }
        return runtimeOwner?.documentSelectionRange(for: anchor, workKey: workKey)
    }

    func likeExcerptSnapshot(workKey: ReadingWorkKey) -> (@Sendable (NovelTextLikeAnchor) -> String?)? {
        guard !isStale else { return nil }
        return runtimeOwner?.likeExcerptSnapshot(generation: generation, workKey: workKey)
    }

    public func draw(in context: CGContext, bounds: CGRect) {
        drawBlockBackgrounds(in: context, bounds: bounds)
        drawText(in: context, bounds: bounds)
    }

    public func drawBlockBackgrounds(in context: CGContext, bounds: CGRect) {
        runtimeOwner?.drawBlockBackgrounds(
            surfaceIdentity: surfaceIdentity,
            in: context,
            bounds: bounds
        )
    }

    public func drawText(in context: CGContext, bounds: CGRect) {
        runtimeOwner?.draw(
            surfaceIdentity: surfaceIdentity,
            in: context,
            bounds: bounds
        )
    }
}

extension NovelTextViewportRuntimeOwner {
    package func displayReference(
        for surfaceIdentity: NovelReaderSurfaceIdentity
    ) -> NovelTextViewportDisplayReference? {
        guard isCurrent(surfaceIdentity) else { return nil }
        return NovelTextViewportDisplayReference(
            runtimeOwner: self,
            surfaceIdentity: surfaceIdentity
        )
    }
}

extension NovelReadingWorkflow {
    public func displayReference(
        for surfaceIdentity: NovelReaderSurfaceIdentity
    ) -> NovelTextViewportDisplayReference? {
        runtime.displayReference(for: surfaceIdentity)
    }
}

import CoreGraphics
import Foundation
import YamiboXCore

/// Opaque drawing handle for one generation-scoped reader surface. Holds only
/// a weak runtime-owner reference plus the surface identity; every query and
/// draw is forwarded through the runtime owner so stale references never draw
/// previous content.
public final class NovelTextViewportDisplayReference {
    public let surfaceIdentity: NovelReaderSurfaceIdentity
    var surfaceOrdinal: Int { surfaceIdentity.ordinal }
    public var generation: UInt64 { surfaceIdentity.generation }

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

    func highlightRange(
        from start: NovelResumePoint,
        to end: NovelResumePoint
    ) -> NovelTextSelectionRange? {
        runtimeOwner?.documentSelectionRange(from: start, to: end)
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
    /// SwiftUI requests opaque display references through the workflow by
    /// complete surface identity; a reference is returned only when that
    /// identity belongs to the active generation.
    public func displayReference(
        for surfaceIdentity: NovelReaderSurfaceIdentity
    ) -> NovelTextViewportDisplayReference? {
        runtime.displayReference(for: surfaceIdentity)
    }
}

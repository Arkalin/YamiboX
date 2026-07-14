import CoreGraphics
import Foundation

package struct NovelTextSurfaceLayoutFragment: Equatable {
    public let characterRange: NSRange
    public let rect: CGRect

    package init(characterRange: NSRange, rect: CGRect) {
        self.characterRange = characterRange
        self.rect = rect
    }
}

package struct NovelTextSurfaceLayoutSlice: Equatable {
    public let characterRange: NSRange
    public let clipRect: CGRect

    package init(characterRange: NSRange, clipRect: CGRect) {
        self.characterRange = characterRange
        self.clipRect = clipRect
    }
}

package enum NovelTextSurfaceFragmentPartitioner {
    package static func partition(
        _ segments: [NovelTextSurfaceLayoutFragment],
        surfaceHeight: CGFloat,
        breakOffsets: Set<Int> = []
    ) -> [NovelTextSurfaceLayoutSlice] {
        guard surfaceHeight > 0 else { return [] }
        var surfaces: [NovelTextSurfaceLayoutSlice] = []
        var currentRange: NSRange?
        var currentClipRect: CGRect?
        for segment in segments {
            guard let existingRange = currentRange,
                  let existingClipRect = currentClipRect else {
                currentRange = segment.characterRange
                currentClipRect = segment.rect
                continue
            }
            if breakOffsets.contains(where: { breakOffset in
                breakOffset > existingRange.location &&
                    breakOffset <= segment.characterRange.location
            }) {
                surfaces.append(
                    NovelTextSurfaceLayoutSlice(
                        characterRange: existingRange,
                        clipRect: existingClipRect
                    )
                )
                currentRange = segment.characterRange
                currentClipRect = segment.rect
                continue
            }
            if segment.characterRange.location < existingRange.location + existingRange.length {
                guard segment.characterRange.location + segment.characterRange.length > existingRange.location + existingRange.length else {
                    continue
                }
                currentRange = existingRange.union(segment.characterRange)
                currentClipRect = existingClipRect.union(segment.rect)
                continue
            }
            let candidateClipRect = existingClipRect.union(segment.rect)
            if candidateClipRect.height > surfaceHeight {
                surfaces.append(
                    NovelTextSurfaceLayoutSlice(
                        characterRange: existingRange,
                        clipRect: existingClipRect
                    )
                )
                currentRange = segment.characterRange
                currentClipRect = segment.rect
            } else {
                currentRange = existingRange.union(segment.characterRange)
                currentClipRect = candidateClipRect
            }
        }
        if let currentRange, let currentClipRect {
            surfaces.append(
                NovelTextSurfaceLayoutSlice(
                    characterRange: currentRange,
                    clipRect: currentClipRect
                )
            )
        }
        return surfaces
    }
}

package enum NovelTextViewportDrawingGeometry {
    package static func clipRect(
        bounds: CGRect,
        surfaceOriginY: CGFloat,
        documentClipMaxY: CGFloat?
    ) -> CGRect {
        guard let documentClipMaxY else { return bounds }
        let clipHeight = min(
            max(documentClipMaxY - surfaceOriginY, 0),
            max(bounds.height, 0)
        )
        return CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: clipHeight
        )
    }

    package static func fragmentStartsInDocumentRange(
        fragmentStart: Int,
        fragmentEnd: Int,
        documentRange: Range<Int>
    ) -> Bool {
        guard fragmentStart != NSNotFound,
              fragmentEnd != NSNotFound,
              fragmentEnd > fragmentStart else {
            return false
        }
        return fragmentStart >= documentRange.lowerBound &&
            fragmentStart < documentRange.upperBound
    }
}

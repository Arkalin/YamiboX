import CoreGraphics

enum NovelReaderVerticalPositioning {
    static func viewportReadingAnchorLineY(in bounds: CGRect) -> CGFloat {
        min(max(bounds.height * 0.16, 96), max(bounds.height - 96, 0))
    }

    static func pageDistance(from referenceLineY: CGFloat, to frame: CGRect) -> CGFloat {
        if frame.contains(CGPoint(x: frame.midX, y: referenceLineY)) {
            return 0
        }
        if referenceLineY < frame.minY {
            return frame.minY - referenceLineY
        }
        return referenceLineY - frame.maxY
    }
}

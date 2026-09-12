import CoreGraphics

/// Chapter geometry in unscaled reader coordinates. Rebuilt for width/ratio
/// changes only; zoom and scroll queries use a binary search.
struct MangaVerticalCollectionZoomLayout: Equatable {
    var pageIDs: [String] = []
    var frames: [CGRect] = []
    var contentSize: CGSize = .zero

    init(pageIDs: [String] = [], width: CGFloat = 0, heightToWidthRatios: [String: CGFloat] = [:]) {
        self.pageIDs = pageIDs
        guard width > 0 else { return }
        var y: CGFloat = 0
        frames = pageIDs.map { id in
            let height = max(ceil(width * (heightToWidthRatios[id] ?? (1 / 0.72))), 160)
            defer { y += height }
            return CGRect(x: 0, y: y, width: width, height: height)
        }
        contentSize = CGSize(width: width, height: y)
    }

    func indexes(intersecting rect: CGRect) -> Range<Int> {
        guard !frames.isEmpty, rect.maxY > 0, rect.minY < contentSize.height else { return 0..<0 }
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY <= rect.minY { low = mid + 1 } else { high = mid }
        }
        let start = low
        while low < frames.count, frames[low].minY < rect.maxY { low += 1 }
        return start..<low
    }

    struct Anchor: Equatable {
        var pageID: String
        var normalizedPoint: CGPoint
        var viewportPoint: CGPoint
    }

    func anchor(at contentPoint: CGPoint, viewportPoint: CGPoint) -> Anchor? {
        guard !frames.isEmpty else { return nil }
        let probe = CGRect(x: 0, y: min(max(contentPoint.y, 0), contentSize.height - 0.001),
                           width: contentSize.width, height: 0.001)
        guard let index = indexes(intersecting: probe).first else { return nil }
        let frame = frames[index]
        return Anchor(pageID: pageIDs[index], normalizedPoint: CGPoint(
            x: (contentPoint.x - frame.minX) / frame.width,
            y: (contentPoint.y - frame.minY) / frame.height
        ), viewportPoint: viewportPoint)
    }

    func contentPoint(for anchor: Anchor) -> CGPoint? {
        guard let index = pageIDs.firstIndex(of: anchor.pageID), frames.indices.contains(index) else { return nil }
        let frame = frames[index]
        return CGPoint(x: frame.minX + frame.width * anchor.normalizedPoint.x,
                       y: frame.minY + frame.height * anchor.normalizedPoint.y)
    }

    func window(covering visibleRect: CGRect) -> CGRect {
        let height = visibleRect.height
        let minY = max(0, visibleRect.minY - height)
        let maxY = min(contentSize.height, visibleRect.maxY + height)
        return CGRect(x: 0, y: minY, width: contentSize.width, height: max(0, maxY - minY))
    }

    static func doubleTapTargetScale(from scale: CGFloat) -> CGFloat {
        MangaPageZoomPolicy.isZoomedForDoubleTapReset(scale) ? 1 : MangaPageZoomPolicy.doubleTapTargetScale
    }
}

#if os(iOS)
import UIKit

final class MangaVerticalNativeCollectionLayout: UICollectionViewLayout {
    var logicalLayout = MangaVerticalCollectionZoomLayout() {
        didSet { invalidateLayout() }
    }

    override var collectionViewContentSize: CGSize { logicalLayout.contentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        logicalLayout.indexes(intersecting: rect).compactMap {
            layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard logicalLayout.frames.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = logicalLayout.frames[indexPath.item]
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }
}
#endif

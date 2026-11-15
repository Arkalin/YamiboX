import UIKit
import YamiboXCore

extension ReaderPageBoundary {
    var message: String {
        switch self {
        case .previous: L10n.string("reader.page_boundary.previous")
        case .next: L10n.string("reader.page_boundary.next")
        }
    }
}

enum ReaderVerticalScrollEvent { case began, dragged(CGFloat), released, settled, cancelled }

enum ReaderVerticalBoundaryAttempt {
    static let triggerDistance: CGFloat = 72

    @MainActor
    static func limits(_ view: UIScrollView) -> ClosedRange<CGFloat> {
        let inset = view.adjustedContentInset
        let minY = -inset.top
        return minY...max(minY, view.contentSize.height - view.bounds.height + inset.bottom)
    }

    static func boundary(
        offsetY: CGFloat,
        minOffsetY: CGFloat,
        maxOffsetY: CGFloat,
        translationY: CGFloat
    ) -> ReaderPageBoundary? {
        if translationY > 0, minOffsetY - offsetY >= triggerDistance { return .previous }
        if translationY < 0, offsetY - maxOffsetY >= triggerDistance { return .next }
        return nil
    }
}

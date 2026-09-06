import Foundation
import YamiboXCore

extension ReaderPageBoundary {
    var message: String {
        switch self {
        case .previous: L10n.string("reader.page_boundary.previous")
        case .next: L10n.string("reader.page_boundary.next")
        }
    }
}

enum ReaderVerticalBoundaryAttempt {
    static let triggerDistance: CGFloat = 72

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

import SwiftUI

/// Only semantic image coordinates cross a display boundary. UIKit still
/// owns the live zoom scale and offset in each mounted viewport.
struct MangaViewportFocus {
    let pageID: String
    let point: CGPoint
    let factor: CGFloat
}

@MainActor
final class MangaViewportHandoff {
    var pendingFocus: MangaViewportFocus?

    func takeFocus(for pageID: String, horizontalHalf: Int? = nil) -> MangaViewportFocus? {
        guard let focus = pendingFocus, focus.pageID == pageID else { return nil }
        pendingFocus = nil
        guard let horizontalHalf else { return focus }
        return MangaViewportFocus(pageID: focus.pageID,
            point: CGPoint(x: (CGFloat(horizontalHalf) + focus.point.x) / 2, y: focus.point.y),
            factor: focus.factor)
    }
}

extension EnvironmentValues {
    @Entry var mangaViewportHandoff: MangaViewportHandoff? = nil
}

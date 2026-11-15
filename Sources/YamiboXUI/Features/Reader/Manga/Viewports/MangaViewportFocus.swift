import SwiftUI

/// Only semantic image coordinates cross display or layout changes. UIKit still
/// owns the live zoom scale and offset in each mounted viewport.
struct MangaViewportFocus {
    let pageID: String
    let point: CGPoint
    let factor: CGFloat
}

@MainActor
final class MangaViewportHandoff {
    var pendingFocus: MangaViewportFocus? {
        didSet {
            if pendingFocus != nil { layoutFocus = nil }
        }
    }
    var layoutFocus: MangaViewportFocus?

    var focusToRestore: MangaViewportFocus? { pendingFocus ?? layoutFocus }

    func consumeFocus(for pageID: String) {
        if pendingFocus?.pageID == pageID { pendingFocus = nil }
        if layoutFocus?.pageID == pageID { layoutFocus = nil }
    }
}

extension EnvironmentValues {
    @Entry var mangaViewportHandoff: MangaViewportHandoff? = nil
}

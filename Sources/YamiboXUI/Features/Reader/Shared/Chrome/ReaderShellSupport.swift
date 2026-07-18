import SwiftUI

#if os(iOS)
import UIKit

/// Window-level metrics shared by both reader shells — previously verbatim
/// per-reader copies that had to be kept in sync by hand.
enum ReaderShellMetrics {
    /// Safe-area insets of the key window. A fullscreen reader's own
    /// GeometryProxy can report zero insets mid-transition, so the shells
    /// clamp against the window's insets instead.
    @MainActor
    static var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets ?? .zero
    }
}

/// Single source of the "may Apple Pencil turn the page" rule: an iPad in
/// paged mode with readable content on screen and nothing (overlay,
/// dismissal, chrome) claiming input. Each reader feeds its own state; the
/// rule itself must not fork per reader.
enum ReaderApplePencilPageTurnGate {
    static func canTurnPage(
        isPadDevice: Bool,
        isPagedReadingMode: Bool,
        hasReadableContent: Bool,
        hasBlockingOverlay: Bool,
        isDismissing: Bool,
        isChromeVisible: Bool
    ) -> Bool {
        isPadDevice
            && isPagedReadingMode
            && hasReadableContent
            && !hasBlockingOverlay
            && !isDismissing
            && !isChromeVisible
    }
}
#endif

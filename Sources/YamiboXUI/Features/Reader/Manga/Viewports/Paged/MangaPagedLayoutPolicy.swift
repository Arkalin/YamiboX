import SwiftUI
import YamiboXCore

/// Status-bar visibility changes chrome, not the reading surface's geometry.
struct MangaReadingViewportInsets {
    private var viewport: CGSize?
    private var reservedTop: CGFloat = 0

    func topInset(for viewport: CGSize, proposed: CGFloat) -> CGFloat {
        self.viewport == viewport ? reservedTop : proposed
    }

    mutating func update(viewport: CGSize, topInset: CGFloat) {
        guard viewport.width > 0, viewport.height > 0, self.viewport != viewport else { return }
        self.viewport = viewport
        reservedTop = topInset
    }
}

enum MangaPagedLayoutPolicy {
    static func usesTwoPageSpread(
        settings: MangaReaderSettings,
        isPadDevice: Bool,
        availableSize: CGSize
    ) -> Bool {
        settings.readingMode == .paged &&
            isPadDevice &&
            availableSize.width.isFinite && availableSize.height.isFinite &&
            availableSize.height > 0 && availableSize.width >= 720 &&
            availableSize.width > availableSize.height
    }

    static func effectivePageScaleMode(
        settings: MangaReaderSettings,
        usesTwoPageSpread: Bool
    ) -> MangaPageScaleMode {
        usesTwoPageSpread ? .fitWidth : settings.pageScaleMode
    }

    /// Vertical (scroll) mode always flows continuously under the notch
    /// regardless of the "ignore top safe area" toggle, so this only ever
    /// reserves space in paged mode when the user turned the toggle off.
    static func pagedContentTopInset(settings: MangaReaderSettings, topInset: CGFloat) -> CGFloat {
        guard settings.readingMode == .paged, !settings.ignoresTopSafeArea else { return 0 }
        return topInset
    }

    /// The outer reader owns the optional top inset. Nested UIKit hosting roots
    /// must not reintroduce the window's top safe area on iPhone.
    static let hostedPageSafeAreaEdges: Edge.Set = .vertical
}

enum MangaPagedViewportResizePolicy {
    static func alignedContentOffsetX(
        previousContentOffsetX: CGFloat,
        previousViewportSize: CGSize?,
        currentViewportSize: CGSize,
        itemCount: Int
    ) -> CGFloat? {
        guard let previousViewportSize,
              previousViewportSize != currentViewportSize,
              previousViewportSize.width > 0,
              previousViewportSize.height > 0,
              currentViewportSize.width > 0,
              currentViewportSize.height > 0,
              itemCount > 0 else {
            return nil
        }

        let itemIndex = Int((previousContentOffsetX / previousViewportSize.width).rounded())
        let clampedItemIndex = min(max(itemIndex, 0), itemCount - 1)
        return CGFloat(clampedItemIndex) * currentViewportSize.width
    }
}

import CoreGraphics
import YamiboXCore

enum MangaPagedLayoutPolicy {
    static func usesTwoPageSpread(
        settings: MangaReaderSettings,
        isPadDevice: Bool,
        availableSize: CGSize
    ) -> Bool {
        settings.readingMode == .paged &&
            settings.showsTwoPagesInLandscapeOnPad &&
            isPadDevice &&
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

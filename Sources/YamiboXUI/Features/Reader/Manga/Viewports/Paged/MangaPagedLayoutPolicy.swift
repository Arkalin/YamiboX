import SwiftUI
import YamiboXCore

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
        availableSize: CGSize
    ) -> Bool {
        settings.readingMode == .paged &&
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

    static func pagedContentTopInset(settings: MangaReaderSettings, topInset: CGFloat) -> CGFloat {
        guard settings.readingMode == .paged, !settings.ignoresTopSafeArea else { return 0 }
        return topInset
    }

    static let hostedPageSafeAreaEdges: Edge.Set = .vertical
}

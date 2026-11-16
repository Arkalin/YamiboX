import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderContentIdentity: Equatable {
    var spreadIDs: [String]
    var pageScaleMode: MangaPageScaleMode
    var pageTurnDirection: MangaPageTurnDirection
    var pageEdgeFillStyle: MangaPageEdgeFillStyle
    var colorScheme: ColorScheme
}

struct MangaPagedReaderSurfaceInteractionIdentity: Equatable {
    var isChromeVisible: Bool
    var zoomEnabled: Bool
}

/// Routes external controls to the mounted backend; absence never means permission to navigate.
@MainActor
final class MangaPagedControlPageTurnBridge {
    struct Sample {
        let page: MangaReaderPageProjection
        let placement: MangaNovelReaderViewportPlacement?
        let focus: MangaViewportFocus?
    }

    var route: ((NavigationStep) -> Void)?
    var pagedSurface: (() -> MangaSurfaceRuntime?)?
    weak var verticalViewport: MangaVerticalCollectionViewport.Coordinator?
    var capturePosition: (() -> Sample?)?

    func requestPageTurn(_ delta: Int) {
        guard let step = NavigationStep(rawValue: delta) else { return }
        route?(step)
    }
}

struct MangaPagedReaderSpreadPageSurface {
    let page: MangaReaderPageProjection
    let surfaceIdentity: MangaPagedReaderPageAppearanceIdentity
    let initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment
    let surfaceInteraction: MangaSurfaceAttachment
    let onLongPress: (MangaReaderPageProjection) -> Void
}

struct MangaPagedReaderPageAppearanceIdentity: Hashable {
    let pageID: String
    let appearanceGeneration: Int
}
#endif

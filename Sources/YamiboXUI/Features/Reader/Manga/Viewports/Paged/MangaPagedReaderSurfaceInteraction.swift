import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderContentIdentity: Equatable {
    var spreadIDs: [String]
    var pageScaleMode: MangaPageScaleMode
    var pagedTurnStyle: ReaderPagedTurnStyle
    var pageTurnDirection: MangaPageTurnDirection
    var pageEdgeFillStyle: MangaPageEdgeFillStyle
    var colorScheme: ColorScheme
}

struct MangaPagedReaderSurfaceInteractionIdentity: Equatable {
    var isChromeVisible: Bool
    var zoomEnabled: Bool
}

/// Routes external controls to the mounted backend; absence never means permission to navigate.
final class MangaPagedControlPageTurnBridge {
    var route: ((NavigationStep) -> Void)?

    func requestPageTurn(_ delta: Int) {
        guard let step = NavigationStep(rawValue: delta) else { return }
        route?(step)
    }
}

struct MangaPagedReaderSpreadPageSurface {
    let page: MangaReaderPageProjection
    let surfaceIdentity: MangaPagedReaderPageAppearanceIdentity
    let initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment
    let surfaceInteraction: MangaPagedReaderPageSurfaceInteraction
    let onLongPress: (MangaReaderPageProjection) -> Void
}

struct MangaPagedReaderPageAppearanceIdentity: Hashable {
    let pageID: String
    let appearanceGeneration: Int
}
#endif

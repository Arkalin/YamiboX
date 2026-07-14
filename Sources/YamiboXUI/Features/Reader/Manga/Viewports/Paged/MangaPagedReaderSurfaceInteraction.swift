import SwiftUI
import Combine
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

struct MangaPagedReaderEdgeRevealRequest {
    let sequence: Int
    let edge: MangaPagedImageSurfaceHorizontalEdge?
}

struct MangaPagedReaderZoomToggleRequest {
    let sequence: Int
    let location: CGPoint?
}

final class MangaPagedReaderPageSurfaceInteraction {
    let edgeRevealRequests = PassthroughSubject<MangaPagedReaderEdgeRevealRequest, Never>()
    let zoomToggleRequests = PassthroughSubject<MangaPagedReaderZoomToggleRequest, Never>()

    private var requestSequence = 0
    private(set) var hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge> = []
    private(set) var isZoomActive = false

    func updateHiddenEdges(_ hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge>) {
        self.hiddenEdges = hiddenEdges
    }

    func updateZoomActive(_ isZoomActive: Bool) {
        self.isZoomActive = isZoomActive
    }

    func hasHiddenContent(onPhysicalEdge edge: MangaPagedImageSurfaceHorizontalEdge) -> Bool {
        hiddenEdges.contains(edge)
    }

    func consumeTap(onPhysicalEdge edge: MangaPagedImageSurfaceHorizontalEdge) -> Bool {
        guard hiddenEdges.contains(edge) else { return false }
        requestSequence += 1
        edgeRevealRequests.send(MangaPagedReaderEdgeRevealRequest(sequence: requestSequence, edge: edge))
        return true
    }

    func requestZoomToggle(at location: CGPoint) {
        requestSequence += 1
        zoomToggleRequests.send(MangaPagedReaderZoomToggleRequest(sequence: requestSequence, location: location))
    }
}

/// Lets a non-touch page-turn trigger (keyboard, gamepad, Apple Pencil) defer
/// to the active paged viewport's own edge-reveal logic before actually
/// turning the page — the same "reveal hidden zoomed/fit-height content on
/// this edge first" decision a tap in the edge zone already makes. Whichever
/// paged viewport (collection-view or page-curl) is currently mounted
/// re-registers `attemptEdgeReveal` on every update, so it always targets the
/// live coordinator.
final class MangaPagedControlPageTurnBridge {
    var attemptEdgeReveal: ((Int) -> Bool)?

    /// Returns `true` when the press was consumed to reveal hidden content
    /// instead of turning the page.
    func attemptPageTurn(_ delta: Int) -> Bool {
        attemptEdgeReveal?(delta) ?? false
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

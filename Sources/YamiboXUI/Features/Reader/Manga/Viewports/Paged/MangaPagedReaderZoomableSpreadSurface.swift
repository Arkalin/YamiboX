import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

struct MangaPagedReaderZoomableSpreadSurface: View {
    let spreadID: String
    let leftPageSurface: MangaPagedReaderSpreadPageSurface?
    let rightPageSurface: MangaPagedReaderSpreadPageSurface?
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isChromeVisible: Bool
    let isZoomInteractionEnabled: Bool
    let spreadSurfaceInteraction: MangaPagedReaderPageSurfaceInteraction
    let likedPageIDs: Set<String>

    @State private var steadyScale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var steadyUserOffset: CGSize = .zero
    @State private var gestureUserOffset: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let layout = spreadSurfaceLayout(containerSize: containerSize, scale: zoomScale)
            let userOffset = proposedUserOffset(layout: layout)
            let displayOffset = layout.displayOffset(forUserOffset: userOffset)
            let hiddenEdges = hiddenHorizontalEdges(layout: layout, userOffset: userOffset)
            let isSurfaceZoomActive = isZoomInteractionEnabled && MangaPageZoomPolicy.isActive(zoomScale)

            ZStack {
                pageEdgeFillStyle.color(for: colorScheme)
                HStack(spacing: 0) {
                    MangaPagedReaderPageSlot(
                        surface: leftPageSurface,
                        imageLoader: imageLoader,
                        pageScaleMode: pageScaleMode,
                        pageEdgeFillStyle: pageEdgeFillStyle,
                        isChromeVisible: isChromeVisible,
                        zoomEnabled: false,
                        allowsUnzoomedSurfacePan: false,
                        isPageZoomEnabled: false,
                        likedPageIDs: likedPageIDs
                    )
                    MangaPagedReaderPageSlot(
                        surface: rightPageSurface,
                        imageLoader: imageLoader,
                        pageScaleMode: pageScaleMode,
                        pageEdgeFillStyle: pageEdgeFillStyle,
                        isChromeVisible: isChromeVisible,
                        zoomEnabled: false,
                        allowsUnzoomedSurfacePan: false,
                        isPageZoomEnabled: false,
                        likedPageIDs: likedPageIDs
                    )
                }
                .frame(width: containerSize.width, height: containerSize.height)
                .scaleEffect(zoomScale)
                .offset(displayOffset)
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(magnifyGesture(containerSize: containerSize))
            .simultaneousGesture(
                dragGesture(containerSize: containerSize),
                including: surfaceDragGestureMask
            )
            .onChange(of: isZoomInteractionEnabled) { _, isEnabled in
                guard !isEnabled else { return }
                resetZoomState(animated: true)
            }
            .onChange(of: spreadID) { _, _ in
                resetZoomState(animated: false)
            }
            .onChange(of: containerSize) { _, newValue in
                clampSteadyUserOffset(containerSize: newValue)
            }
            .onChange(of: hiddenEdges, initial: true) { _, newValue in
                spreadSurfaceInteraction.updateHiddenEdges(newValue)
            }
            .onChange(of: isSurfaceZoomActive, initial: true) { _, newValue in
                spreadSurfaceInteraction.updateZoomActive(newValue)
            }
            .onReceive(spreadSurfaceInteraction.edgeRevealRequests) { request in
                guard let edge = request.edge else { return }
                revealHiddenContent(on: edge, containerSize: containerSize)
            }
            .onReceive(spreadSurfaceInteraction.zoomToggleRequests) { request in
                guard isZoomInteractionEnabled,
                      let location = request.location else {
                    return
                }
                toggleZoom(at: location, containerSize: containerSize)
            }
            .onDisappear {
                spreadSurfaceInteraction.updateHiddenEdges([])
                spreadSurfaceInteraction.updateZoomActive(false)
            }
        }
    }

    private var zoomScale: CGFloat {
        clampedScale(steadyScale * gestureScale)
    }

    private var surfaceDragGestureMask: GestureMask {
        // `.gesture` would disable the long-press hit region nested inside each page
        // slot (a subview) whenever the spread is zoomed and panning.
        surfaceDragGestureEnabled ? .all : .subviews
    }

    private var surfaceDragGestureEnabled: Bool {
        isZoomInteractionEnabled && MangaPageZoomPolicy.isActive(zoomScale)
    }

    private func magnifyGesture(containerSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isZoomInteractionEnabled else { return }
                let nextScale = clampedScale(steadyScale * value.magnification)
                gestureScale = nextScale / max(steadyScale, 0.001)
                let layout = spreadSurfaceLayout(containerSize: containerSize, scale: nextScale)
                steadyUserOffset = layout.clampedUserOffset(steadyUserOffset)
            }
            .onEnded { value in
                guard isZoomInteractionEnabled else { return }
                let nextScale = clampedScale(steadyScale * value.magnification)
                steadyScale = nextScale
                gestureScale = 1
                if nextScale <= 1.01 {
                    resetZoomState(animated: true)
                } else {
                    let layout = spreadSurfaceLayout(containerSize: containerSize, scale: nextScale)
                    steadyUserOffset = layout.clampedUserOffset(steadyUserOffset)
                }
            }
    }

    private func dragGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard surfaceDragGestureEnabled else { return }
                let layout = spreadSurfaceLayout(containerSize: containerSize, scale: zoomScale)
                let proposed = CGSize(
                    width: steadyUserOffset.width + value.translation.width,
                    height: steadyUserOffset.height + value.translation.height
                )
                let clamped = layout.clampedUserOffset(proposed)
                gestureUserOffset = CGSize(
                    width: clamped.width - steadyUserOffset.width,
                    height: clamped.height - steadyUserOffset.height
                )
            }
            .onEnded { value in
                guard surfaceDragGestureEnabled else {
                    gestureUserOffset = .zero
                    return
                }
                let layout = spreadSurfaceLayout(containerSize: containerSize, scale: steadyScale)
                let proposed = CGSize(
                    width: steadyUserOffset.width + value.translation.width,
                    height: steadyUserOffset.height + value.translation.height
                )
                steadyUserOffset = layout.clampedUserOffset(proposed)
                gestureUserOffset = .zero
            }
    }

    private func toggleZoom(at location: CGPoint, containerSize: CGSize) {
        if MangaPageZoomPolicy.isZoomedForDoubleTapReset(steadyScale) {
            resetZoomState(animated: true)
        } else {
            zoomIn(to: location, containerSize: containerSize)
        }
    }

    private func zoomIn(to location: CGPoint, containerSize: CGSize) {
        let targetScale = MangaPageZoomPolicy.doubleTapTargetScale
        let targetLayout = spreadSurfaceLayout(containerSize: containerSize, scale: targetScale)

        withAnimation(.easeOut(duration: 0.2)) {
            steadyScale = targetScale
            gestureScale = 1
            steadyUserOffset = targetLayout.userOffsetAnchoring(location)
            gestureUserOffset = .zero
        }
    }

    private func revealHiddenContent(
        on edge: MangaPagedImageSurfaceHorizontalEdge,
        containerSize: CGSize
    ) {
        let layout = spreadSurfaceLayout(containerSize: containerSize, scale: zoomScale)
        let userOffset = proposedUserOffset(layout: layout)
        guard let targetUserOffset = layout.userOffsetRevealingContent(on: edge, fromUserOffset: userOffset) else {
            spreadSurfaceInteraction.updateHiddenEdges(hiddenHorizontalEdges(layout: layout, userOffset: userOffset))
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            steadyUserOffset = targetUserOffset
            gestureUserOffset = .zero
        }
    }

    private func resetZoomState(animated: Bool) {
        let updates = {
            steadyScale = 1
            gestureScale = 1
            steadyUserOffset = .zero
            gestureUserOffset = .zero
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2), updates)
        } else {
            updates()
        }
    }

    private func clampSteadyUserOffset(containerSize: CGSize) {
        let layout = spreadSurfaceLayout(containerSize: containerSize, scale: steadyScale)
        steadyUserOffset = layout.clampedUserOffset(steadyUserOffset)
        gestureUserOffset = .zero
    }

    private func proposedUserOffset(layout: MangaPagedSpreadSurfaceZoomLayout) -> CGSize {
        layout.clampedUserOffset(
            CGSize(
                width: steadyUserOffset.width + gestureUserOffset.width,
                height: steadyUserOffset.height + gestureUserOffset.height
            )
        )
    }

    private func hiddenHorizontalEdges(
        layout: MangaPagedSpreadSurfaceZoomLayout,
        userOffset: CGSize
    ) -> Set<MangaPagedImageSurfaceHorizontalEdge> {
        Set(
            MangaPagedImageSurfaceHorizontalEdge.allCases.filter { edge in
                layout.hasHiddenContent(on: edge, fromUserOffset: userOffset)
            }
        )
    }

    private func spreadSurfaceLayout(containerSize: CGSize, scale: CGFloat) -> MangaPagedSpreadSurfaceZoomLayout {
        MangaPagedSpreadSurfaceZoomLayout(
            containerSize: containerSize,
            zoomScale: scale
        )
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        MangaPageZoomPolicy.clampedScale(scale)
    }
}
#endif

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
    @State private var pinchStartScale: CGFloat?
    @State private var pinchStartDisplayOffset: CGSize?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let layout = spreadSurfaceLayout(containerSize: containerSize, scale: zoomScale)
            let userOffset = proposedUserOffset(layout: layout)
            let displayOffset = layout.liveDisplayOffset(forUserOffset: userOffset)
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
        // `gestureScale` is maintained pre-attenuated (rubber-banded) by the
        // live pinch, and `steadyScale` is hard-clamped whenever it settles,
        // so the product is already the displayable scale.
        steadyScale * gestureScale
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
                if pinchStartScale == nil {
                    pinchStartScale = steadyScale
                    pinchStartDisplayOffset = steadyUserOffset
                }
                let displayScale = MangaPageZoomPolicy.rubberBandedScale(steadyScale * value.magnification)
                gestureScale = displayScale / max(steadyScale, 0.001)
                steadyUserOffset = focalUserOffset(
                    displayScale: displayScale,
                    startAnchor: value.startAnchor,
                    containerSize: containerSize
                )
            }
            .onEnded { value in
                defer {
                    pinchStartScale = nil
                    pinchStartDisplayOffset = nil
                }
                guard isZoomInteractionEnabled else { return }
                let displayScale = MangaPageZoomPolicy.rubberBandedScale(steadyScale * value.magnification)
                let settleScale = clampedScale(steadyScale * value.magnification)
                // Freeze the on-screen scale into steady state (no visual
                // change), then spring any overshoot back to the bound.
                steadyScale = displayScale
                gestureScale = 1
                if settleScale <= MangaPageZoomPolicy.activeThreshold {
                    resetZoomState(animated: true)
                } else {
                    let targetLayout = spreadSurfaceLayout(containerSize: containerSize, scale: settleScale)
                    withAnimation(.gestureSettle) {
                        steadyScale = settleScale
                        steadyUserOffset = targetLayout.clampedUserOffset(steadyUserOffset)
                    }
                }
            }
    }

    /// Keeps the content point under the pinch's start anchor fixed while the
    /// scale changes, so the detail being inspected doesn't drift toward the
    /// container center.
    private func focalUserOffset(
        displayScale: CGFloat,
        startAnchor: UnitPoint,
        containerSize: CGSize
    ) -> CGSize {
        let layout = spreadSurfaceLayout(containerSize: containerSize, scale: displayScale)
        guard let pinchStartScale,
              let pinchStartDisplayOffset,
              pinchStartScale > 0 else {
            return layout.rubberBandedUserOffset(steadyUserOffset)
        }
        let ratio = displayScale / pinchStartScale
        let anchor = CGPoint(
            x: startAnchor.x * containerSize.width,
            y: startAnchor.y * containerSize.height
        )
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        return layout.rubberBandedUserOffset(
            CGSize(
                width: (anchor.x - center.x) * (1 - ratio) + pinchStartDisplayOffset.width * ratio,
                height: (anchor.y - center.y) * (1 - ratio) + pinchStartDisplayOffset.height * ratio
            )
        )
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
                let banded = layout.rubberBandedUserOffset(proposed)
                gestureUserOffset = CGSize(
                    width: banded.width - steadyUserOffset.width,
                    height: banded.height - steadyUserOffset.height
                )
            }
            .onEnded { value in
                guard surfaceDragGestureEnabled else {
                    gestureUserOffset = .zero
                    return
                }
                let layout = spreadSurfaceLayout(containerSize: containerSize, scale: steadyScale)
                let current = layout.rubberBandedUserOffset(
                    CGSize(
                        width: steadyUserOffset.width + value.translation.width,
                        height: steadyUserOffset.height + value.translation.height
                    )
                )
                let projection = GesturePhysics.project(value.velocity)
                let target = layout.clampedUserOffset(
                    CGSize(
                        width: current.width + projection.width,
                        height: current.height + projection.height
                    )
                )
                // Freeze the on-screen offset, then continue toward the
                // projected landing point at the finger's release speed.
                steadyUserOffset = current
                gestureUserOffset = .zero
                let initialVelocity = GesturePhysics.relativeVelocity(value.velocity, from: current, to: target)
                withAnimation(.gestureMomentum(initialVelocity: initialVelocity)) {
                    steadyUserOffset = target
                }
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

        withAnimation(.gestureSettle) {
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

        withAnimation(.gestureSettle) {
            steadyUserOffset = targetUserOffset
            gestureUserOffset = .zero
        }
    }

    private func resetZoomState(animated: Bool) {
        pinchStartScale = nil
        pinchStartDisplayOffset = nil
        let updates = {
            steadyScale = 1
            gestureScale = 1
            steadyUserOffset = .zero
            gestureUserOffset = .zero
        }

        if animated {
            withAnimation(.gestureSettle, updates)
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
        // Already rubber-banded when written by the live gesture; clamping
        // here would flatten the overshoot mid-drag.
        CGSize(
            width: steadyUserOffset.width + gestureUserOffset.width,
            height: steadyUserOffset.height + gestureUserOffset.height
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

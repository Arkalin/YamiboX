import SwiftUI
import YamiboXCore

#if os(iOS)
import UIKit

@MainActor
final class MangaPagedSurfacePanGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    private var shouldBeginHandler: (CGSize, CGSize) -> Bool
    private var onChangedHandler: (CGSize) -> Void
    private var onEndedHandler: (CGSize) -> Void
    private var onCancelledHandler: () -> Void

    init(
        shouldBegin: @escaping (CGSize, CGSize) -> Bool,
        onChanged: @escaping (CGSize) -> Void,
        onEnded: @escaping (CGSize) -> Void,
        onCancelled: @escaping () -> Void
    ) {
        self.shouldBeginHandler = shouldBegin
        self.onChangedHandler = onChanged
        self.onEndedHandler = onEnded
        self.onCancelledHandler = onCancelled
    }

    func update(
        shouldBegin: @escaping (CGSize, CGSize) -> Bool,
        onChanged: @escaping (CGSize) -> Void,
        onEnded: @escaping (CGSize) -> Void,
        onCancelled: @escaping () -> Void
    ) {
        shouldBeginHandler = shouldBegin
        onChangedHandler = onChanged
        onEndedHandler = onEnded
        onCancelledHandler = onCancelled
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
            return false
        }
        let translationPoint = panGesture.translation(in: panGesture.view)
        let velocityPoint = panGesture.velocity(in: panGesture.view)
        let translation = CGSize(width: translationPoint.x, height: translationPoint.y)
        let velocity = CGSize(width: velocityPoint.x, height: velocityPoint.y)
        return shouldBeginHandler(translation, velocity)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer is UIPinchGestureRecognizer ||
            otherGestureRecognizer is UILongPressGestureRecognizer
    }

    func handle(state: UIGestureRecognizer.State, translation: CGSize) {
        switch state {
        case .changed:
            onChangedHandler(translation)
        case .ended:
            onEndedHandler(translation)
        case .cancelled, .failed:
            onCancelledHandler()
        default:
            break
        }
    }
}

struct MangaPagedSurfacePanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let shouldBegin: (CGSize, CGSize) -> Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> MangaPagedSurfacePanGestureCoordinator {
        MangaPagedSurfacePanGestureCoordinator(
            shouldBegin: shouldBegin,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.update(
            shouldBegin: shouldBegin,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
        if recognizer.isEnabled != isEnabled {
            recognizer.isEnabled = isEnabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translationPoint = context.converter.localTranslation ?? recognizer.translation(in: recognizer.view)
        let translation = CGSize(width: translationPoint.x, height: translationPoint.y)
        context.coordinator.handle(state: recognizer.state, translation: translation)
    }
}

struct MangaPagedReaderPageSurface: View {
    let page: MangaReaderPageProjection
    let surfaceIdentity: MangaPagedReaderPageAppearanceIdentity
    let imageLoader: MangaReaderPageImageLoader
    let pageScaleMode: MangaPageScaleMode
    let initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isChromeVisible: Bool
    let zoomEnabled: Bool
    let allowsUnzoomedSurfacePan: Bool
    let surfaceInteraction: MangaPagedReaderPageSurfaceInteraction
    let likedPageIDs: Set<String>
    let onLongPress: (MangaReaderPageProjection) -> Void

    @State private var loadedImage: UIImage?
    @State private var loadedPageID: String?
    @State private var loadingPageID: String?
    @State private var failedPageID: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            pageEdgeFillStyle.color(for: colorScheme)

            if let image = displayedImage {
                MangaPagedReaderScaledImage(
                    image: image,
                    pageID: page.id,
                    pageScaleMode: pageScaleMode,
                    initialHorizontalAlignment: initialHorizontalAlignment,
                    pageEdgeFillStyle: pageEdgeFillStyle,
                    isSurfaceInteractionEnabled: !isChromeVisible,
                    isZoomInteractionEnabled: !isChromeVisible && zoomEnabled,
                    allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan,
                    surfaceInteraction: surfaceInteraction,
                    onLongPress: {
                        onLongPress(page)
                    }
                )
                .id(surfaceIdentity)
            } else if loadingPageID == page.id {
                ReaderLoadStateView(
                    status: .loading,
                    tint: pageEdgeFillStyle.progressTint(for: colorScheme)
                )
            } else if failedPageID == page.id {
                ReaderLoadStateView(
                    status: .failed(title: L10n.string("image.load_failed"), message: ""),
                    retryAction: {
                        Task { await loadImage() }
                    },
                    tint: pageEdgeFillStyle.placeholderForeground(for: colorScheme)
                )
            } else {
                ReaderLoadStateView(
                    status: .loading,
                    tint: pageEdgeFillStyle.placeholderForeground(for: colorScheme)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if likedPageIDs.contains(page.id) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .task(id: page.id) { @MainActor in
            await loadImage()
        }
    }

    private var displayedImage: UIImage? {
        if let cachedImage = imageLoader.cachedImage(for: page) {
            return cachedImage
        }
        guard loadedPageID == page.id else { return nil }
        return loadedImage
    }

    @MainActor
    private func loadImage() async {
        if let cachedImage = imageLoader.cachedImage(for: page) {
            loadedImage = cachedImage
            loadedPageID = page.id
            loadingPageID = nil
            failedPageID = nil
            return
        }

        loadingPageID = page.id
        failedPageID = nil

        do {
            let image = try await imageLoader.image(for: page)
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedPageID = page.id
            loadingPageID = nil
            failedPageID = nil
        } catch {
            guard !Task.isCancelled else { return }
            if loadedPageID != page.id {
                loadedImage = nil
            }
            loadingPageID = nil
            failedPageID = page.id
        }
    }
}

private struct MangaPagedReaderScaledImage: View {
    let image: UIImage
    let pageID: String
    let pageScaleMode: MangaPageScaleMode
    let initialHorizontalAlignment: MangaPagedImageSurfaceInitialHorizontalAlignment
    let pageEdgeFillStyle: MangaPageEdgeFillStyle
    let isSurfaceInteractionEnabled: Bool
    let isZoomInteractionEnabled: Bool
    let allowsUnzoomedSurfacePan: Bool
    let surfaceInteraction: MangaPagedReaderPageSurfaceInteraction
    let onLongPress: () -> Void

    @State private var steadyScale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var steadyUserOffset: CGSize = .zero
    @State private var gestureUserOffset: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let layout = imageSurfaceLayout(containerSize: containerSize, scale: zoomScale)
            let userOffset = proposedUserOffset(layout: layout)
            let displayOffset = layout.displayOffset(forUserOffset: userOffset)
            let longPressFrame = MangaPageLongPressHitTesting.allowedFrame(
                in: CGRect(origin: .zero, size: containerSize),
                imageFrame: layout.displayedImageFrame(forUserOffset: userOffset)
            )
            let hiddenEdges = hiddenHorizontalEdges(layout: layout, userOffset: userOffset)
            let isSurfaceZoomActive = isZoomInteractionEnabled && MangaPageZoomPolicy.isActive(zoomScale)
            let isSurfacePanEnabled = MangaPagedSurfaceDragIntent.isSurfacePanEnabled(
                isInteractionEnabled: isSurfaceInteractionEnabled,
                allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan,
                isZoomActive: isSurfaceZoomActive,
                hiddenEdges: hiddenEdges
            )

            ZStack {
                pageEdgeFillStyle.color(for: colorScheme)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: layout.contentSize.width, height: layout.contentSize.height)
                    .offset(displayOffset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Keep hit testing in the fixed viewport coordinate space, not the wider image space.
            .overlay {
                MangaPagedReaderLongPressHitRegion(
                    frame: longPressFrame,
                    onLongPress: onLongPress
                )
            }
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(magnifyGesture(containerSize: containerSize))
            .gesture(
                surfacePanGesture(
                    containerSize: containerSize,
                    isEnabled: isSurfacePanEnabled,
                    isZoomActive: isSurfaceZoomActive,
                    hiddenEdges: hiddenEdges
                )
            )
            .onChange(of: isZoomInteractionEnabled) { _, isEnabled in
                guard !isEnabled else { return }
                endSurfaceInteraction(animated: true)
            }
            .onChange(of: isSurfaceInteractionEnabled) { _, isEnabled in
                guard !isEnabled else { return }
                endSurfaceInteraction(animated: true)
            }
            .onChange(of: pageID) { _, _ in
                resetZoomState(animated: false)
            }
            .onChange(of: pageScaleMode) { _, _ in
                resetZoomState(animated: false)
            }
            .onChange(of: initialHorizontalAlignment) { _, _ in
                resetZoomState(animated: false)
            }
            .onChange(of: containerSize) { _, newValue in
                clampSteadyUserOffset(containerSize: newValue)
            }
            .onChange(of: hiddenEdges, initial: true) { _, newValue in
                surfaceInteraction.updateHiddenEdges(newValue)
            }
            .onChange(of: isSurfaceZoomActive, initial: true) { _, newValue in
                surfaceInteraction.updateZoomActive(newValue)
            }
            .onReceive(surfaceInteraction.edgeRevealRequests) { request in
                guard let edge = request.edge else { return }
                revealHiddenContent(on: edge, containerSize: containerSize)
            }
            .onReceive(surfaceInteraction.zoomToggleRequests) { request in
                guard isZoomInteractionEnabled,
                      let location = request.location else {
                    return
                }
                toggleZoom(at: location, containerSize: containerSize)
            }
            .onDisappear {
                surfaceInteraction.updateHiddenEdges([])
                surfaceInteraction.updateZoomActive(false)
            }
        }
    }

    private var zoomScale: CGFloat {
        clampedScale(steadyScale * gestureScale)
    }

    private func magnifyGesture(containerSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isZoomInteractionEnabled else { return }
                let nextScale = clampedScale(steadyScale * value.magnification)
                gestureScale = nextScale / max(steadyScale, 0.001)
                let layout = imageSurfaceLayout(containerSize: containerSize, scale: nextScale)
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
                    let layout = imageSurfaceLayout(containerSize: containerSize, scale: nextScale)
                    steadyUserOffset = layout.clampedUserOffset(steadyUserOffset)
                }
            }
    }

    private func surfacePanGesture(
        containerSize: CGSize,
        isEnabled: Bool,
        isZoomActive: Bool,
        hiddenEdges: Set<MangaPagedImageSurfaceHorizontalEdge>
    ) -> MangaPagedSurfacePanGesture {
        MangaPagedSurfacePanGesture(
            isEnabled: isEnabled,
            shouldBegin: { translation, velocity in
                MangaPagedSurfaceDragIntent.shouldBeginSurfacePan(
                    isInteractionEnabled: isSurfaceInteractionEnabled,
                    allowsUnzoomedSurfacePan: allowsUnzoomedSurfacePan,
                    isZoomActive: isZoomActive,
                    hiddenEdges: hiddenEdges,
                    translation: translation,
                    velocity: velocity
                )
            },
            onChanged: { translation in
                guard isSurfaceInteractionEnabled,
                      let translation = surfaceDragTranslation(translation) else {
                    return
                }
                let layout = imageSurfaceLayout(containerSize: containerSize, scale: zoomScale)
                let proposed = CGSize(
                    width: steadyUserOffset.width + translation.width,
                    height: steadyUserOffset.height + translation.height
                )
                let clamped = layout.clampedUserOffset(proposed)
                gestureUserOffset = CGSize(
                    width: clamped.width - steadyUserOffset.width,
                    height: clamped.height - steadyUserOffset.height
                )
            },
            onEnded: { translation in
                guard isSurfaceInteractionEnabled,
                      let translation = surfaceDragTranslation(translation) else {
                    gestureUserOffset = .zero
                    return
                }
                let layout = imageSurfaceLayout(containerSize: containerSize, scale: steadyScale)
                let proposed = CGSize(
                    width: steadyUserOffset.width + translation.width,
                    height: steadyUserOffset.height + translation.height
                )
                steadyUserOffset = layout.clampedUserOffset(proposed)
                gestureUserOffset = .zero
            },
            onCancelled: {
                gestureUserOffset = .zero
            }
        )
    }

    private func surfaceDragTranslation(_ translation: CGSize) -> CGSize? {
        if isZoomInteractionEnabled && MangaPageZoomPolicy.isActive(zoomScale) {
            return translation
        }
        guard allowsUnzoomedSurfacePan else { return nil }
        return MangaPagedSurfaceDragIntent.unzoomedSurfaceTranslation(translation)
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
        let targetLayout = imageSurfaceLayout(containerSize: containerSize, scale: targetScale)
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        let targetLocation = CGRect(origin: .zero, size: containerSize).contains(location)
            ? location
            : center
        let proposedDisplayOffset = CGSize(
            width: -(targetLocation.x - center.x) * targetScale,
            height: -(targetLocation.y - center.y) * targetScale
        )
        let proposedUserOffset = CGSize(
            width: proposedDisplayOffset.width - targetLayout.restingOffset.width,
            height: proposedDisplayOffset.height - targetLayout.restingOffset.height
        )

        withAnimation(.easeOut(duration: 0.2)) {
            steadyScale = targetScale
            gestureScale = 1
            steadyUserOffset = targetLayout.clampedUserOffset(proposedUserOffset)
            gestureUserOffset = .zero
        }
    }

    private func revealHiddenContent(
        on edge: MangaPagedImageSurfaceHorizontalEdge,
        containerSize: CGSize
    ) {
        let layout = imageSurfaceLayout(containerSize: containerSize, scale: zoomScale)
        let userOffset = proposedUserOffset(layout: layout)
        guard let targetUserOffset = layout.userOffsetRevealingContent(on: edge, fromUserOffset: userOffset) else {
            surfaceInteraction.updateHiddenEdges(hiddenHorizontalEdges(layout: layout, userOffset: userOffset))
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

    private func endSurfaceInteraction(animated: Bool) {
        guard MangaPagedSurfaceDragIntent.shouldResetOffsetWhenInteractionDisables(zoomScale: zoomScale) else {
            gestureScale = 1
            gestureUserOffset = .zero
            return
        }
        resetZoomState(animated: animated)
    }

    private func clampSteadyUserOffset(containerSize: CGSize) {
        let layout = imageSurfaceLayout(containerSize: containerSize, scale: steadyScale)
        steadyUserOffset = layout.clampedUserOffset(steadyUserOffset)
        gestureUserOffset = .zero
    }

    private func proposedUserOffset(layout: MangaPagedImageSurfaceLayout) -> CGSize {
        layout.clampedUserOffset(
            CGSize(
                width: steadyUserOffset.width + gestureUserOffset.width,
                height: steadyUserOffset.height + gestureUserOffset.height
            )
        )
    }

    private func hiddenHorizontalEdges(
        layout: MangaPagedImageSurfaceLayout,
        userOffset: CGSize
    ) -> Set<MangaPagedImageSurfaceHorizontalEdge> {
        Set(
            MangaPagedImageSurfaceHorizontalEdge.allCases.filter { edge in
                layout.hasHiddenContent(on: edge, fromUserOffset: userOffset)
            }
        )
    }

    private func imageSurfaceLayout(containerSize: CGSize, scale: CGFloat) -> MangaPagedImageSurfaceLayout {
        MangaPagedImageSurfaceLayout(
            imageSize: image.size,
            containerSize: containerSize,
            pageScaleMode: pageScaleMode,
            initialHorizontalAlignment: initialHorizontalAlignment,
            zoomScale: scale
        )
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        MangaPageZoomPolicy.clampedScale(scale)
    }
}

private struct MangaPagedReaderLongPressHitRegion: View {
    let frame: CGRect
    let onLongPress: () -> Void

    var body: some View {
        if frame.width > 0, frame.height > 0 {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .onLongPressGesture(minimumDuration: 0.45, perform: onLongPress)
        }
    }
}
#endif
